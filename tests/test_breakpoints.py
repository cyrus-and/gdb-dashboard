"""Run with python3 -m unittest discover -s tests (requires GDB and a C compiler)."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class BreakpointsTest(unittest.TestCase):
    def test_enabled_and_disabled_without_ansi(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            source = directory / 'fixture.c'
            binary = directory / 'fixture'
            source.write_text('int value = 1;\n'
                              'int main(void) { return value - 1; }\n')
            subprocess.run([os.environ.get('CC', 'cc'), '-g', '-O0',
                            str(source), '-o', str(binary)], check=True)
            commands = directory / 'commands.gdb'
            commands.write_text(r'''set confirm off
set disable-randomization off
source {dashboard}
dashboard -style ansi False
dashboard -layout breakpoints
file {binary}
break main
run
python
import re
text = gdb.execute('dashboard', to_string=True)
assert re.search(r'\[1\] break at ', text), text
assert 'disabled break' not in text, text
end
disable 1
python
text = gdb.execute('dashboard', to_string=True)
assert '[1] disabled break at ' in text, text
end
enable 1
watch value
python
text = gdb.execute('dashboard', to_string=True)
assert re.search(r'\[2\] (write )?watch for value', text), text
assert 'disabled' not in text, text
end
disable 2
python
text = gdb.execute('dashboard', to_string=True)
assert re.search(r'\[2\] disabled (write )?watch for value', text), text
end
continue
'''.format(dashboard=root / '.gdbinit', binary=binary))
            env = dict(os.environ, HOME=str(directory),
                       XDG_CONFIG_HOME=str(directory / '.config'))
            result = subprocess.run(['gdb', '-nx', '-nh', '-batch', '-x',
                                     str(commands)], env=env,
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
