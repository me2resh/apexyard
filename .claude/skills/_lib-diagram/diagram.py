#!/usr/bin/env python3
"""Diagram library CLI. No skills call this library yet."""

import argparse
import json
import sys

from layout import layout
from mermaid import check, emit
from model import BadInput, load, validate


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('validate', 'mermaid', 'layout', 'check'):
        command = commands.add_parser(name)
        command.add_argument('path')
        command.add_argument('--repo-dir', help='Clone containing the pinned commit')
    args = parser.parse_args(argv)
    try:
        if args.command == 'check':
            errors = check(args.path, args.repo_dir)
        else:
            model, errors, warnings = validate(load(args.path), args.repo_dir)
            for warning in warnings:
                print(warning, file=sys.stderr)
            if not errors:
                if args.command == 'mermaid':
                    sys.stdout.write(emit(model))
                elif args.command == 'layout':
                    print(json.dumps(layout(model), sort_keys=True, ensure_ascii=True, separators=(',', ':')))
        for error in errors:
            print(error, file=sys.stderr)
        return 1 if errors else 0
    except BadInput as exc:
        print('E_INPUT /: ' + str(exc), file=sys.stderr)
        return 2
    except (OSError, ValueError) as exc:
        print('E_INPUT /: Cannot read diagram input or repository data.', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
