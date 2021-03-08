#!env python3
import argparse
import difflib
from pathlib import Path
import re
from dbalib.sqlparser import DDLScript
from pglast.enums import ObjectType
from pglast import Node, _remove_stmt_len_and_location
from pglast.printers import ddl
from pglast.printer import IndentedStream

DESCRIPTION = """
This program takes a migration identified by it's project and version number,
and compares it to the previou schema dump available for this project.

For every function which was already existing in the previous dump but was
changd during the migration, we output the unified diff for the function.
"""

EPILOG="""
Example truncated usage:

    ~/./diff_functions.py demo 1.2
    Will compare against dump demo/schemas/demo-schema_1.1.sql
    Function public.immutable_unaccent has changed:
    --- demo-schema_1.1.sql

    +++ 1.2-fix_similarity_search-010-ddl.sql

    @@ -1,5 +1,3 @@

     CREATE OR REPLACE FUNCTION public.immutable_unaccent(text)
    -RETURNS text LANGUAGE sql immutable PARALLEL SAFE SET search_path TO 'public'
    -AS $$
    -          SELECT public.unaccent($1);
    -        $$
    +RETURNS text AS 'unaccent.so'
    +              , 'unaccent_dict' LANGUAGE c immutable STRICT PARALLEL SAFE
"""

def argparser():
    argparser = argparse.ArgumentParser(
            description=DESCRIPTION,
            epilog=EPILOG,
            formatter_class=argparse.RawDescriptionHelpFormatter)
    argparser.add_argument("project",
                           help="The project on which we want to work")
    argparser.add_argument("version",
                           help="The version needing to be diffed")
    return argparser


def get_all_functions(ddlscript):
    functions = {}
    for stmt in ddlscript.statements:
        if stmt.node_tag == 'CreateFunctionStmt':
            _remove_stmt_len_and_location(stmt.parse_tree)
            if len(stmt.funcname) == 1:
                # Add public before that
                stmt.parse_tree['funcname'] = [
                        {'String': {'str': 'public'}},
                        {'String': stmt.funcname[0].parse_tree}
                ]
            name = '.'.join([a.string_value for a in stmt.funcname])
            # Add "OR REPLACE" everywhere to not confuse the diff.
            stmt.parse_tree['replace'] = True
            functions[name] = (IndentedStream()(stmt), stmt)
    return functions


if __name__ == '__main__':
    args = argparser().parse_args()
    project_folder = Path(args.project)
    version_folder = project_folder / args.version
    schemas_folder = project_folder / 'schemas'
    # Find the version immediately prior to this one
    child_dirs = list(sorted(project_folder.iterdir()))
    previous_version = None
    for version, next_version in zip(child_dirs,
                                     child_dirs[1:]):
        if next_version.name == args.version:
            previous_version = version.name
            break
    if previous_version is None:
        raise ValueError('Could not locate the previous version for %s' %
                         args.version)
    previous_version = tuple(map(int, previous_version.split('.')))
    # Then find the closest version for which we have a dump
    extract_version_name = re.compile('%s-schema[-_](.*).sql' % args.project)
    candidate_dump = None
    for dump in sorted(schemas_folder.glob('%s-schema*.sql' % args.project)):
        match = extract_version_name.match(dump.name)
        if match and match.group(1):
            version_num = tuple(map(int, match.group(1).split('.')))
            # Consider it a candidate
            if version_num <= previous_version:
                candidate_dump = dump
            else:
                break
    print("Will compare against dump %s" % candidate_dump)
    # Since we have a valid dump to compare against, load it. It will serve as
    # reference when comparing functions.
    schema_dump = DDLScript.load_from_file(candidate_dump)
    # Extract all function statements from the dump.
    previous_versions_functions = get_all_functions(schema_dump)
    # Now, we can iterate over all migration script, and build a diff
    for migration_file in sorted(version_folder.glob('*.sql')):
        if migration_file.is_symlink():
            continue
        script = DDLScript.load_from_file(migration_file)
        new_functions = get_all_functions(script)
        if not new_functions:
            continue
        for name, (stmt, parse_tree) in new_functions.items():
            old_stmt, old_parse_tree = previous_versions_functions.get(name, (None, None))
            if old_stmt is not None:
                print("Function %s has changed: " % name)
                diff = difflib.unified_diff(old_stmt.split('\n'),
                                            stmt.split('\n'),
                                            fromfile=candidate_dump.name,
                                            tofile=migration_file.name)
                for line in diff:
                    print(line)
                print("")
