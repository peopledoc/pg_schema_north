#!python3
from pglast import parse_sql, Node, enums
from dbalib.sqlparser.parser import Parser, comments_on_same_line
import argparse
import pathlib
import psycopg2
import warnings
from sqlalchemy import (
        Table, MetaData, Column, create_engine, exc as sa_exc,
        column)
from sqlalchemy.sql.expression import ColumnCollection
from itertools import combinations, product
import sys


TABLE_CACHE = {}

def argparser():
    argparser = argparse.ArgumentParser()
    argparser.add_argument("--uri",
                           help="URI to connect to the DB containing the schema")
    argparser.add_argument("sqlfile",
                           nargs=1,
                           help="The sql file to check")
    return argparser


class IncorrectSQL(Exception):

    def __init__(self, message, node=None):
        self.message = message
        self.node = node

    def __str__(self):
        if self.node is None:
            return self.message
        return "%s (at char %s)" % (self.message,
                                    self.node.location.value)


class CTEWrapper(object):

    def __init__(self, name, columns=None):
        self.name = name
        self.columns = columns or ColumnCollection()


def qualify_table(table_name, schema_name, search_path, db_conn):
    if schema_name:
        search_path = [schema_name]
    search_path = ["pg_catalog"] + search_path
    query = """
    SELECT oid, relname, schema::text FROM (
        SELECT oid, relname, relnamespace
        FROM pg_class
        WHERE relname = %(table)s
            AND relnamespace = ANY(%(search_path)s::regnamespace[])
    ) t
    JOIN unnest(%(search_path)s::regnamespace[]) WITH ORDINALITY as sp(schema, ord)
         ON sp.schema = t.relnamespace
    ORDER BY ord
    LIMIT 1;
    """
    rs = db_conn.execute(query, {"table":table_name, "search_path": search_path})
    if not rs:
        raise IncorrectSQL('Could not find a matching table')
    return rs.first() or (None,None,None)


def get_table(range_var, search_path, metadata, ctes):
    table_name = range_var.relname.value
    schema_name = get_schemaname(range_var)
    if table_name in ctes:
        return ctes[table_name]
    # A bit dirty, but we attach information directly to
    # the pglast parse_tree to avoid expansive round trips to the DB
    if id(range_var.parse_tree) in TABLE_CACHE:
        return TABLE_CACHE[id(range_var.parse_tree)]
    conn = metadata.bind.connect()
    oid, table_name, schema_name = qualify_table(table_name, schema_name,
                                                 search_path, conn)
    if oid is None:
        return None
    table = Table(table_name, metadata, schema=schema_name, autoload=True)
    if range_var.alias:
        table = table.alias(range_var.alias.aliasname.value)
    TABLE_CACHE[id(range_var.parse_tree)] = table
    return table


def get_schemaname(rangevar):
    if rangevar.schemaname:
        return rangevar.schemaname.value
    return None


def match_colref(expression, tables):
    coldef = expression.fields
    col = None
    # This is an unqualified column, so look in every possible table
    # to resolve it
    if len(coldef) == 1:
        if coldef[0].node_tag == 'A_Star':
            print("WARNING: '*' in query, this can cause problems")
            cols = []
            for table in tables:
                cols.extend(table.columns)
            return cols
        colname = coldef[0].string_value
        for table in tables:
            if colname in table.columns:
                if col is not None:
                    raise IncorrectSQL('Ambiguous column name %s' % colname)
                col = table.columns[colname]
    # This is a qualified column, so look into the right table
    elif len(coldef) == 2:
        tablename = coldef[0].string_value
        colname = coldef[1].string_value
        for table in tables:
            if table.name == tablename:
                col = table.columns.get(colname)
                if col is None:
                    raise IncorrectSQL("Column %s.%s does not exist" % (
                                        tablename, colname))
                break
    return [col]


def _match_cols(expression, tables):
    if expression.node_tag == 'ColumnRef':
        return match_colref(expression, tables)
    elif expression.node_tag == 'RowExpr':
        retval = []
        for arg in expression.args:
            retval.extend(match_colref(arg, tables))
        return retval
    # Not sure if we should inspect further down here, or just bail out
    elif expression.node_tag == 'TypeCast':
        return match_cols(expression.arg, tables)
    elif expression.node_tag == 'A_Const':
        return []
    elif expression.node_tag == 'FuncCall':
        return []
    elif expression.node_tag == 'A_Expr':
        return []
    elif expression.node_tag == 'A_Indirection':
        return []
    elif expression.node_tag == 'CoalesceExpr':
        return []
    elif expression.node_tag == 'CaseExpr':
        return []
    else:
        raise IncorrectSQL('No idea what to do with %s' % expression.node_tag)

def match_cols(expression, tables):
    return [item for item in _match_cols(expression, tables) if item is not
            None]


def get_base_column(col):
    if len(col.base_columns) > 1:
        raise ValueError("Can't get base column from %s" % col)
    bc = list(col.base_columns)[0]
    if bc != col:
        return get_base_column(bc)
    return bc


def point_to_same(lcol, rcol):
    """
    Returns wether both columns have an FK to the same column.
    """
    for lfk, rfk in product(lcol.foreign_keys, rcol.foreign_keys):
        if lfk.column == rfk.column:
            return True
    return False


def ensure_join_respect_fks(left_table, right_table, qual):
    # Standard case: we have a
    if qual.node_tag == 'A_Expr':
        aek = enums.A_Expr_Kind
        if qual.kind in (aek.AEXPR_OP, aek.AEXPR_NOT_DISTINCT):
            # Common case, it's an operator expression or a NOT_DISTINCT
            lcols = match_cols(qual.lexpr, [left_table, right_table])
            rcols = match_cols(qual.rexpr, [left_table, right_table])
            # Now, make sure we have a FK between left and right columns
            for lcol, rcol in zip(lcols, rcols):
                is_a_match = False
                # Resolve the column, if it's a label for example
                baselcol = get_base_column(lcol)
                basercol = get_base_column(rcol)
                if baselcol.references(basercol) or basercol.references(baselcol):
                    is_a_match = True
                # Those are the same columns
                if lcol in rcol.proxy_set or rcol in lcol.proxy_set:
                    is_a_match = True
                if point_to_same(lcol, rcol):
                    is_a_match = True
                if not is_a_match:
                    raise IncorrectSQL('Join between %s and %s does not have an FK' %
                                       (lcol, rcol), qual)
        elif qual.kind == aek.AEXPR_DISTINCT:
            pass
        elif qual.kind == aek.AEXPR_IN:
            pass
        else:
            raise IncorrectSQL('Do not know what to do with this kind of qual')
    elif qual.node_tag == 'BoolExpr':
        # Check for every argument. We don't really care if it's an OR or an
        # AND
        for arg in qual.args:
            ensure_join_respect_fks(left_table, right_table, arg)
    else:
        pass


def _extract_range_vars(node):
    return [n for n in node.traverse()
            if getattr(n, 'node_tag', None) == 'RangeVar']


def check_explicit_joins(statement, search_path, metadata, ctes):
    for node in statement.traverse():
        if isinstance(node, Node) and node.node_tag == 'JoinExpr':
            # We don't need to recurse, since statement.traverse() will
            # traverse the recursively.
            # However, if we have a join expr on the left or right side, we
            # need to flatten then so that we can check every combination.
            # Eg: A JOIN B ON () JOIN C ON () should check for FK between A and
            # C and between B and C (of course, the first join expr A JOIN B
            # will be checked as traverse() recurse into it.
            left_tables = _extract_range_vars(node.larg)
            right_tables = _extract_range_vars(node.rarg)
            for left, right in product(left_tables, right_tables):
                left_table = get_table(left,
                                       search_path,
                                       metadata,
                                       ctes)
                if left_table is None:
                    raise IncorrectSQL('Could not find table in %s' %
                                       left)
                right_table = get_table(right,
                                        search_path,
                                        metadata,
                                        ctes)

                if right_table is None:
                    raise IncorrectSQL('Could not find table in %s' %
                                       right.parse_tree)
                # Now, try to match the columns in the predicate to either the left
                # or right table.
                if node.joinType == enums.JoinType.JOIN_INNER and not node.quals:
                    ensure_join_respect_fks(left_table, right_table, node.quals)



def check_implicit_joins(statement, search_path, metadata, ctes):
    # If no where clause, then there is obviously no join
    if not statement.whereClause:
        return
    if not statement.fromClause:
        return
    all_rels = [node for node in statement.fromClause
                if node.node_tag == 'RangeVar']
    if statement.node_tag == 'UpdateStmt':
        all_rels.append(statement.relation)

    all_tables = [x for x in (get_table(rel, search_path, metadata, ctes)
                              for rel in all_rels)
                  if x is not None]

    # Now that we have all tables, try to see if we have implicit joins between
    # them
    for left_table, right_table in combinations(all_tables, 2):
        ensure_join_respect_fks(left_table, right_table, statement.whereClause)


def check_where_clause(statement, search_path, metadata):
    if not statement.whereClause:
        raise IncorrectSQL('%s should have a where clause !' %
                           statement.node_tag)


def extract_ctes(nodes, search_path, metadata):
    ctes = {}
    # Build a list of columns
    for ctenode in nodes:
        query = ctenode.ctequery
        all_tables = []
        all_targets = list(query.targetList) or []
        if query.node_tag in ('InsertStmt', 'UpdateStmt', 'DeleteStmt'):
            all_tables.append(get_table(query.relation,
                                        search_path,
                                        metadata,
                                        ctes))
            all_targets.extend(query.returningList)
        if query.fromClause:
            rangevars = _extract_range_vars(ctenode.ctequery.fromClause)
            all_tables = [x for x in (get_table(rel, search_path, metadata, ctes)
                                      for rel in rangevars)]
        name = ctenode.ctename.value
        ctes[name] = cte = CTEWrapper(name)
        for restarget in all_targets:
            cols = match_cols(restarget.val, all_tables)
            if not cols:
                # Couldn't find the column from underlying tables, so add it as
                # is.
                cols = [Column(coldef.string_value)
                        for coldef in restarget.val.fields]
            # This is not supported, throw an error for now
            if len(cols) == 0:
                continue
            if len(cols) > 1:
                for col in cols:
                    cte.columns.add(col)
                continue
            # Add the column to the CTE, relabeling it in the process.
            col = cols[0]
            # If there is an alias, use it.
            if restarget.name:
                col = col.label(restarget.name.value)
            cte.columns.add(col)
    return ctes


def process_statement(statement, search_path, default_search_path):
    seen = set()
    if statement.node_tag == 'CreateTableAsStmt':
        if statement.into.rel.relpersistence not in (enums.RELPERSISTENCE_TEMP,
                                                     enums.RELPERSISTENCE_UNLOGGED):
            raise IncorrectSQL("CreateTableAsStmt is forbidden unless temp or unlogged")
    if statement.node_tag == 'VariableSetStmt':
        vsk = enums.VariableSetKind
        if statement.kind == vsk.VAR_RESET_ALL:
            search_path = default_search_path
            return search_path
        if statement.name == 'search_path':
            if statement.kind == vsk.VAR_RESET:
                search_path = default_search_path
            else:
                search_path = [arg.val.string_value for arg in statement.args]
            return search_path
    for node in statement.traverse():
        # Bypass scalar and list nodes.
        if not isinstance(node, Node):
            continue
        # Since some nodes (CTEs) can be accessed by several means,
        # make sure we don't process a node twice
        if id(node) in seen:
            continue
        seen.add(id(node))
        # First, add "virtual" tables for the CTEs
        if node.withClause:
            ctes = extract_ctes(node.withClause.ctes, search_path,
                                metadata)
        else:
            ctes = {}
        try:
            if node.node_tag in ('UpdateStmt', 'SelectStmt'):
                # Check explicit joins
                check_explicit_joins(node, search_path, metadata, ctes)
                # Check implicit joins (ie, cartesian product + predicate)
                check_implicit_joins(node, search_path, metadata, ctes)
            if node.node_tag in ('UpdateStmt', 'DeleteStmt'):
                # Check where clause
                check_where_clause(node, search_path, metadata)
        except IncorrectSQL as e:
            # See if we should ignore the node
            has_error = True
            if e.node:
                for comment in comments_on_same_line(e.node, statement):
                    if comment.comment == 'sql_check:disable':
                        has_error = False
                        break
            if has_error:
                raise e
    return search_path


if __name__ == '__main__':
    args = argparser().parse_args()
    with open(args.sqlfile[0]) as f:
        sqlcontents = f.read()
    p = Parser(validate=False)
    p.feed(sqlcontents)
    default_search_path = search_path = ['public']
    engine = create_engine(args.uri)
    metadata = MetaData(bind=engine)
    # Remove annoying warning about partial and expression based indexes
    # not being reflected
    warnings.filterwarnings("ignore", category=sa_exc.SAWarning)
    has_error = False
    try:
        stmts = list(p.statements)
    except Exception as e:
        print("Error while parsing file %s" % f.name)
        print(e)
        sys.exit(1)

    for statement in stmts:
        try:
            search_path = process_statement(statement, search_path,
                                            default_search_path)
        except IncorrectSQL as e:
            print("Error while parsing file %s" % f.name)
            print(e)
            sys.exit(1)
