from pathlib import Path
import shutil
import sys
import pytest
from hardware_runtime import run_tool
from run_hardware import runner_command


def test_nonzero_tool_status_preserves_stderr(tmp_path):
    result = run_tool([sys.executable, '-c', 'import sys; print("bad", file=sys.stderr); sys.exit(3)'], tmp_path)
    assert result['status'] == 'failed'
    assert result['exit_code'] == 3
    assert result['stderr'].strip() == 'bad'


def test_missing_tool_is_blocked(tmp_path):
    result = run_tool([str(tmp_path/'unavailable-vivado')], tmp_path)
    assert result['status'] == 'blocked'
    assert result['exit_code'] is None


def test_upstream_nms_rtl(tmp_path):
    if not shutil.which('iverilog'):
        pytest.skip('Install Icarus Verilog to run the RTL integration test')
    root = Path(__file__).resolve().parents[1]
    result = run_tool(['iverilog','-g2012','-s','tb_dataerai_nms','-o',str(tmp_path/'nms.vvp'),
                       str(root/'08_hls_design/TopCrop.sv'),str(root/'tests/tb_dataerai_nms.sv')],tmp_path)
    assert result['exit_code'] == 0, result['stderr']
    result = run_tool(['vvp', str(tmp_path/'nms.vvp')], tmp_path)
    assert result['exit_code'] == 0, result
    assert 'PASS: NMS' in result['stdout']
    assert (tmp_path/'nms-waveform.vcd').stat().st_size > 0


def test_timed_out_command_retains_partial_streams(tmp_path):
    import sys
    from hardware_runtime import run_tool
    result=run_tool([sys.executable,'-u','-c',"import time,sys;print('partial acquisition');print('device waiting',file=sys.stderr);time.sleep(10)"],tmp_path,timeout=0.5)
    assert result['status']=='timed_out'
    assert result['stdout']=='partial acquisition\n'
    assert result['stderr']=='device waiting\n'


def test_requested_missing_output_fails_capture(tmp_path):
    import pytest
    from hardware_runtime import capture_outputs
    with pytest.raises(FileNotFoundError):
        capture_outputs(None,[str(tmp_path/'missing.bit')],role='firmware')


def test_hardware_wrapper_forwards_collection_affixes(tmp_path):
    args = type('Args', (), {
        'timeout': 60,
        'collection_prefix': 'September batch',
        'collection_postfix': 'rerun 2',
    })()
    command = runner_command(tmp_path, tmp_path / 'request.ipynb', args)
    assert command[-4:] == [
        '--collection-prefix', 'September batch',
        '--collection-postfix', 'rerun 2',
    ]
