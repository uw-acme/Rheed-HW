"""Wrap a user-selected simulation, synthesis, build or acquisition command in provenance."""
import argparse
from pathlib import Path
import subprocess
import sys
import uuid
import nbformat


def runner_command(root: Path, notebook: Path, args) -> list[str]:
    command = [
        sys.executable,
        str(root / 'run_dataerai.py'),
        str(notebook),
        '--workdir',
        str(root),
        '--timeout',
        str(args.timeout + 300),
    ]
    if args.collection_prefix is not None:
        command.extend(['--collection-prefix', args.collection_prefix])
    if args.collection_postfix is not None:
        command.extend(['--collection-postfix', args.collection_postfix])
    return command


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', choices=['simulation','synthesis','implementation','acquisition'], required=True)
    parser.add_argument('--input', action='append', default=[])
    parser.add_argument('--output', action='append', default=[])
    parser.add_argument('--timeout', type=int, default=3600)
    parser.add_argument('--collection-prefix')
    parser.add_argument(
        '--collection-postfix', '--collection-suffix', dest='collection_postfix'
    )
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('Provide the command after --')
    root = Path(__file__).resolve().parent
    path = root / '.dataerai' / 'requests' / f'{args.stage}-{uuid.uuid4()}.ipynb'
    path.parent.mkdir(parents=True, exist_ok=True)
    data_mode = 'experimental' if args.stage == 'acquisition' else 'simulation' if args.stage == 'simulation' else 'build'
    output_role = 'raw_data' if args.stage == 'acquisition' else 'analysis' if args.stage == 'simulation' else 'firmware'
    nb = nbformat.v4.new_notebook()
    nb.cells = [
        nbformat.v4.new_markdown_cell(f'# RHEED {args.stage}\nThis records the supplied command; no hardware access occurs unless that command requests it.'),
        nbformat.v4.new_code_cell(f'from pathlib import Path\nimport os\nos.environ["RHEED_DATA_MODE"] = {data_mode!r}\nfrom rheed_runtime import setup, capture_directory\nfrom hardware_runtime import run_tool, source_manifest, capture_outputs\ndataerai = setup({str(path)!r})', metadata={'tags':['dataerai-setup']}),
        nbformat.v4.new_code_cell('%%dataerai\nsource_inventory = source_manifest(Path.cwd())'),
        nbformat.v4.new_code_cell(f'%%dataerai\nfor input_path in {args.input!r}:\n    dataerai.capture_file(input_path, role="source", relationship="uses_dependency")'),
        nbformat.v4.new_code_cell(f'%%dataerai\nstage = {args.stage!r}\ntool_result = run_tool({command!r}, Path.cwd(), timeout={args.timeout})\nprint(tool_result)\ncapture_outputs(dataerai, {args.output!r}, role={output_role!r})\nassert tool_result["status"] == "succeeded", tool_result'),
        nbformat.v4.new_code_cell('dataerai.finish()', metadata={'tags':['dataerai-finish']}),
    ]
    nbformat.write(nb, path)
    # Kernel working directory remains the repository, while the immutable source
    # notebook is retained under .dataerai/requests.
    return subprocess.call(runner_command(root, path, args), cwd=root)


if __name__ == '__main__':
    raise SystemExit(main())
