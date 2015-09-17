python

# GDB dashboard - Modular visual interface for GDB in Python.
#
# https://github.com/cyrus-and/gdb-dashboard

import ast
import fcntl
import os
import struct
import termios

# Common attributes ------------------------------------------------------------

class R():

    @staticmethod
    def attributes():
        return {
            # miscellaneous
            'ansi': {
                'doc': 'Control the ANSI output of the dashboard.',
                'default': True,
                'type': bool
            },
            # prompt
            'prompt': {
                'doc': """Command prompt.
This value is parsed as a Python format string in which `{status}` is expanded
with the substitution of either `prompt_running` or `prompt_not_running`
attributes, according to the target program status. The resulting string must be
a valid GDB prompt, see the command `python print(gdb.prompt.prompt_help())`""",
                'default': '{status}'
            },
            'prompt_running': {
                'doc': """`{status}` when the target program is running.
See the `prompt` attribute. This value is parsed as a Python format string in
which `{pid}` is expanded with the process identifier of the target program.""",
                'default': '\[\e[1;35m\]>>>\[\e[0m\]'
            },
            'prompt_not_running': {
                'doc': '`{status}` when the target program is not running.',
                'default': '\[\e[1;30m\]>>>\[\e[0m\]'
            },
            # divider
            'divider_fill_char_primary': {
                'doc': 'Filler around the label for primary dividers',
                'default': '─'
            },
            'divider_fill_char_secondary': {
                'doc': 'Filler around the label for secondary dividers',
                'default': '─'
            },
            'divider_fill_style_primary': {
                'doc': 'Style for `divider_fill_char_primary`',
                'default': '36'
            },
            'divider_fill_style_secondary': {
                'doc': 'Style for `divider_fill_char_secondary`',
                'default': '1;30'
            },
            'divider_label_style_on_primary': {
                'doc': 'Label style for non-empty primary dividers',
                'default': '1;33'
            },
            'divider_label_style_on_secondary': {
                'doc': 'Label style for non-empty secondary dividers',
                'default': '0'
            },
            'divider_label_style_off_primary': {
                'doc': 'Label style for empty primary dividers',
                'default': '33'
            },
            'divider_label_style_off_secondary': {
                'doc': 'Label style for empty secondary dividers',
                'default': '1;30'
            },
            'divider_label_skip': {
                'doc': 'Gap between the aligning border and the label.',
                'default': 3,
                'type': int,
                'check': check_ge_zero
            },
            'divider_label_margin': {
                'doc': 'Number of spaces around the label.',
                'default': 1,
                'type': int,
                'check': check_ge_zero
            },
            'divider_label_align_right': {
                'doc': 'Label alignment flag.',
                'default': False,
                'type': bool
            },
            # common styles
            'style_selected_1': {
                'default': '1;32'
            },
            'style_selected_2': {
                'default': '32'
            },
            'style_low': {
                'default': '1;30'
            },
            'style_high': {
                'default': '1;37'
            },
            'style_error': {
                'default': '31'
            }
        }

# Common -----------------------------------------------------------------------

def run(command):
    return gdb.execute(command, to_string=True)

def ansi(string, style):
    if R.ansi:
        return '\x1b[{}m{}\x1b[0m'.format(style, string)
    else:
        return string

def divider(label='', primary=False, active=True):
    width = Dashboard.term_width
    if primary:
        divider_fill_style = R.divider_fill_style_primary
        divider_fill_char = R.divider_fill_char_primary
        divider_label_style_on = R.divider_label_style_on_primary
        divider_label_style_off = R.divider_label_style_off_primary
    else:
        divider_fill_style = R.divider_fill_style_secondary
        divider_fill_char = R.divider_fill_char_secondary
        divider_label_style_on = R.divider_label_style_on_secondary
        divider_label_style_off = R.divider_label_style_off_secondary
    if label:
        if active:
            divider_label_style = divider_label_style_on
        else:
            divider_label_style = divider_label_style_off
        skip = R.divider_label_skip
        margin = R.divider_label_margin
        before = ansi(divider_fill_char * skip, divider_fill_style)
        middle = ansi(label, divider_label_style)
        after_length = width - len(label) - skip - 2 * margin
        after = ansi(divider_fill_char * after_length, divider_fill_style)
        if R.divider_label_align_right:
            before, after = after, before
        return ''.join([before, ' ' * margin, middle, ' ' * margin, after])
    else:
        return ansi(divider_fill_char * width, divider_fill_style)

def check_gt_zero(x):
    return x > 0

def check_ge_zero(x):
    return x >= 0

def to_unsigned(value, size=8):
    # values from GDB can be used transparently but are not suitable for
    # being printed as unsigned integers, so a conversion is needed
    return int(value.cast(gdb.Value(0).type)) % (2 ** (size * 8))

def format_address(address):
    return '0x{:016x}'.format(address)

# Dashboard --------------------------------------------------------------------

class Dashboard(gdb.Command):
    """Redisplay the dashboard."""

    def __init__(self):
        gdb.Command.__init__(self, 'dashboard',
                             gdb.COMMAND_USER, gdb.COMPLETE_NONE, True)
        self.output = None  # main terminal
        self.enabled = True
        # setup subcommands
        Dashboard.OutputCommand(self)
        Dashboard.EnabledCommand(self)
        Dashboard.LayoutCommand(self)
        # setup style commands
        Dashboard.StyleCommand(self, 'dashboard', R, R.attributes())
        # setup events
        gdb.events.cont.connect(lambda _: self.on_continue())
        gdb.events.stop.connect(lambda _: self.on_stop())
        gdb.events.exited.connect(lambda _: self.on_exit())

    def on_continue(self):
        # try to contain the GDB messages is a specified are unless the
        # dashboard is printed to a separate file
        if self.enabled and self.is_running() and not self.output:
            Dashboard.update_term_width()
            gdb.write(Dashboard.clear_screen())
            gdb.write(divider('Output/messages', True))
            gdb.write('\n')
            gdb.flush()

    def on_stop(self):
        # redisplay the dashboard when the target program stops (the screen is
        # cleared by on_continue when the dashboard is printed to a separate
        # file)
        if self.enabled and self.is_running():
            clear = Dashboard.clear_screen() if self.output else ''
            self.display(clear, self.build(), '\n')

    def on_exit(self):
        pass

    def load_modules(self, modules):
        self.modules = []
        for module in modules:
            info = Dashboard.ModuleInfo(self, module)
            self.modules.append(info)

    def redisplay(self):
        # manually redisplay the dashboard
        if self.is_running():
            self.display(Dashboard.clear_screen(), self.build(), '')

    def inferior_pid(self):
        return gdb.selected_inferior().pid

    def is_running(self):
        return self.inferior_pid() != 0

    def build(self):
        # fetch the output width
        try:
            fd = self.output.fileno() if self.output else 1  # main terminal
            Dashboard.update_term_width(fd)
        except:
            # fall back to the main terminal
            Dashboard.update_term_width()
        # fetch lines
        lines = []
        for module in self.modules:
            if not module.enabled:
                continue
            module = module.instance
            # active if more than zero lines
            module_lines = module.lines()
            lines.append(divider(module.label(), True, module_lines))
            lines.extend(module_lines)
        if len(lines) == 0:
            lines.append(divider('Error', True))
            if len(self.modules) == 0:
                lines.append('No module loaded')
            else:
                lines.append('No module to display (see `help dashboard`)')
        lines.append(divider(primary=True))
        # print the dashboard
        return '\n'.join(lines)

    def display(self, *data):
        # gdb module has both write() and flush()
        try:
            output = self.output or gdb
            for string in data:
                output.write(string)
            output.flush()
        except:
            Dashboard.err('Cannot write the dashboard')

# Utility methods --------------------------------------------------------------

    @staticmethod
    def start():
        # initialize the dashboard
        dashboard = Dashboard()
        Dashboard.set_custom_prompt(dashboard)
        # parse Python inits, load modules then parse GDB inits
        Dashboard.parse_inits(True)
        modules = Dashboard.get_modules()
        dashboard.load_modules(modules)
        Dashboard.parse_inits(False)
        # GDB overrides
        run('set pagination off')
        run('alias -a db = dashboard')

    @staticmethod
    def update_term_width(fd=1):  # defaults to the main terminal
        # first 2 shorts (4 byte) of struct winsize
        raw = fcntl.ioctl(fd, termios.TIOCGWINSZ, ' ' * 4)
        height, width = struct.unpack('hh', raw)
        Dashboard.term_width = int(width)

    @staticmethod
    def set_custom_prompt(dashboard):
        def custom_prompt(_):
            # render thread status indicator
            if dashboard.is_running():
                pid = dashboard.inferior_pid()
                status = R.prompt_running.format(pid=pid)
            else:
                status = R.prompt_not_running
            # build prompt
            prompt = R.prompt.format(status=status)
            prompt = gdb.prompt.substitute_prompt(prompt)
            return prompt + ' '  # force trailing space
        gdb.prompt_hook = custom_prompt

    @staticmethod
    def parse_inits(python):
        for root, dirs, files in os.walk(os.path.expanduser('~/.gdbinit.d/')):
            dirs.sort()
            for init in sorted(files):
                path = os.path.join(root, init)
                _, ext = os.path.splitext(path)
                # either load Python files or GDB
                if python ^ (ext != '.py'):
                    gdb.execute('source ' + path)

    @staticmethod
    def get_modules():
        # scan the scope for modules
        modules = []
        for name in globals():
            obj = globals()[name]
            try:
                if issubclass(obj, Dashboard.Module):
                    modules.append(obj)
            except TypeError:
                continue
        # sort modules alphabetically
        modules.sort(key=lambda x: x.__name__)
        return modules

    @staticmethod
    def create_command(name, invoke, doc, is_prefix, complete=None):
        Class = type('', (gdb.Command,), {'invoke': invoke, '__doc__': doc})
        Class(name, gdb.COMMAND_USER, complete or gdb.COMPLETE_NONE, is_prefix)

    @staticmethod
    def err(string):
        print(ansi(string, R.style_error))

    @staticmethod
    def complete(word, candidates):
        matching = []
        for candidate in candidates:
            if candidate.startswith(word):
                matching.append(candidate)
        return matching

    @staticmethod
    def parse_arg(arg):
        # encode unicode GDB command arguments as utf8 in Python 2.7
        if type(arg) is not str:
            arg = arg.encode('utf8')
        return arg

    @staticmethod
    def clear_screen():
        return '\x1b[H\x1b[2J'

# Module descriptor ------------------------------------------------------------

    class ModuleInfo:

        def __init__(self, dashboard, module):
            self.name = module.__name__.lower()  # from class to module name
            self.enabled = True
            self.instance = module()
            self.doc = self.instance.__doc__ or '(no documentation)'
            self.prefix = 'dashboard {}'.format(self.name)
            # add GDB commands
            self.add_main_command(dashboard)
            self.add_style_command(dashboard)
            self.add_subcommands(dashboard)

        def add_main_command(self, dashboard):
            module = self
            def invoke(self, arg, from_tty, info=self):
                arg = Dashboard.parse_arg(arg)
                if arg == '':
                    info.enabled ^= True
                    if dashboard.is_running():
                        dashboard.redisplay()
                    else:
                        status = 'enabled' if info.enabled else 'disabled'
                        print('{} module {}'.format(module.name, status))
                else:
                    Dashboard.err('Wrong argument "{}"'.format(arg))
            doc_brief = 'Configure the {} module.'.format(self.name)
            doc_extended = 'Toggle the module visibility.'
            doc = '{}\n{}\n\n{}'.format(doc_brief, doc_extended, self.doc)
            Dashboard.create_command(self.prefix, invoke, doc, True)

        def add_style_command(self, dashboard):
            if 'attributes' in dir(self.instance):
                Dashboard.StyleCommand(dashboard, self.prefix, self.instance,
                                       self.instance.attributes())

        def add_subcommands(self, dashboard):
            if 'commands' in dir(self.instance):
                for name, command in self.instance.commands().items():
                    self.add_subcommand(dashboard, name, command)

        def add_subcommand(self, dashboard, name, command):
            action = command['action']
            doc = command['doc']
            complete = command.get('complete')
            def invoke(self, arg, from_tty, info=self):
                arg = Dashboard.parse_arg(arg)
                if info.enabled:
                    try:
                        action(arg)
                    except Exception as e:
                        Dashboard.err(e)
                        return
                    # don't catch redisplay errors
                    dashboard.redisplay()
                else:
                    Dashboard.err('Module disabled')
            prefix = '{} {}'.format(self.prefix, name)
            Dashboard.create_command(prefix, invoke, doc, False, complete)

# GDB commands -----------------------------------------------------------------

    def invoke(self, arg, from_tty):
        arg = Dashboard.parse_arg(arg)
        if arg == '':
            if self.is_running():
                self.redisplay()
            else:
                Dashboard.err('Is the target program running?')
        else:
            Dashboard.err('Wrong argument "{}"'.format(arg))

    class OutputCommand(gdb.Command):
        """Set the dashboard output file/TTY.
The dashboard will be appended to the specified file, which will be created if
it does not exists. If the specified file identifies a terminal then its width
will be used to format the dashboard, otherwise falls back to the width of the
main GDB terminal. Without argument the dashboard will be printed on standard
output (default)."""

        def __init__(self, dashboard):
            gdb.Command.__init__(self, 'dashboard -output',
                                 gdb.COMMAND_USER, gdb.COMPLETE_FILENAME)
            self.dashboard = dashboard

        def invoke(self, arg, from_tty):
            arg = Dashboard.parse_arg(arg)
            # close the previous output file, if any
            if self.dashboard.output:
                self.dashboard.output.close()
            # set or open the output file
            if arg == '':
                self.dashboard.output = None
            else:
                try:
                    self.dashboard.output = open(arg, 'w')
                except:
                    Dashboard.err('Cannot open "{}"'.format(arg))
            # redisplay the dashboard in the new output
            self.dashboard.redisplay()

    class EnabledCommand(gdb.Command):
        """Enable or disable the dashboard [on|off].
The current status is printed if no argument is present."""

        def __init__(self, dashboard):
            gdb.Command.__init__(self, 'dashboard -enabled', gdb.COMMAND_USER)
            self.dashboard = dashboard

        def invoke(self, arg, from_tty):
            arg = Dashboard.parse_arg(arg)
            if arg == '':
                status = 'enabled' if self.dashboard.enabled else 'disabled'
                print('The dashboard is {}'.format(status))
            elif arg == 'on':
                self.dashboard.enabled = True
                self.dashboard.redisplay()
            elif arg == 'off':
                self.dashboard.enabled = False
            else:
                msg = 'Wrong argument "{}"; expecting "on" or "off"'
                Dashboard.err(msg.format(arg))

        def complete(self, text, word):
            return Dashboard.complete(word, ['on', 'off'])

    class LayoutCommand(gdb.Command):
        """Set or show the dashboard layout.
Accepts a space-separated list of directive. Each directive is in the form
"[!]<module>". Modules in the list are placed in the dashboard in the same order
as they appear and those prefixed by "!" are disabled by default. Omitted
modules are hidden and placed at the bottom in alphabetical order. Without
arguments the current layout is shown; enabled and disabled modules are properly
marked."""

        def __init__(self, dashboard):
            gdb.Command.__init__(self, 'dashboard -layout', gdb.COMMAND_USER)
            self.dashboard = dashboard

        def invoke(self, arg, from_tty):
            arg = Dashboard.parse_arg(arg)
            directives = str(arg).split()
            if directives:
                self.layout(directives)
                if from_tty and not self.dashboard.is_running():
                    self.show()
            else:
                self.show()

        def show(self):
            for module in self.dashboard.modules:
                style = R.style_high if module.enabled else R.style_low
                print(ansi(module.name, style))

        def layout(self, directives):
            modules = self.dashboard.modules
            # reset visibility
            for module in modules:
                module.enabled = False
            # move and enable the selected modules on top
            last = 0
            n_enabled = 0
            for directive in directives:
                # parse next directive
                enabled = (directive[0] != '!')
                name = directive[not enabled:]
                try:
                    # it may actually start from last, but in this way repeated
                    # modules can be handler transparently and without error
                    todo = enumerate(modules[last:], start=last)
                    index = next(i for i, m in todo if name == m.name)
                    modules[index].enabled = enabled
                    modules.insert(last, modules.pop(index))
                    last += 1
                    n_enabled += enabled
                except StopIteration:
                    def find_module(x):
                        return x.name == name
                    first_part = modules[:last]
                    if len(filter(find_module, first_part)) == 0:
                        Dashboard.err('Cannot find module "{}"'.format(name))
                    else:
                        Dashboard.err('Module "{}" already set'.format(name))
                    continue
            # redisplay the dashboard
            if n_enabled:
                self.dashboard.redisplay()

        def complete(self, text, word):
            all_modules = (m.name for m in self.dashboard.modules)
            return Dashboard.complete(word, all_modules)

    class StyleCommand(gdb.Command):
        """Access the stylable attributes.
Without arguments print all the stylable attributes. Subcommands are used to set
or print (when the value is omitted) individual attributes."""

        def __init__(self, dashboard, prefix, obj, attributes):
            self.prefix = prefix + ' -style'
            gdb.Command.__init__(self, self.prefix,
                                 gdb.COMMAND_USER, gdb.COMPLETE_NONE, True)
            self.dashboard = dashboard
            self.obj = obj
            self.attributes = attributes
            self.add_styles()

        def add_styles(self):
            this = self
            for name, attribute in self.attributes.items():
                # fetch fields
                attr_name = attribute.get('name', name)
                attr_type = attribute.get('type', str)
                attr_check = attribute.get('check', lambda _: True)
                attr_default = attribute['default']
                # set the default value (coerced to the type)
                value = attr_type(attr_default)
                setattr(self.obj, attr_name, value)
                # create the command
                def invoke(self, arg, from_tty, name=name, attr_name=attr_name,
                           attr_type=attr_type, attr_check=attr_check):
                    new_value = Dashboard.parse_arg(arg)
                    if new_value == '':
                        # print the current value
                        value = getattr(this.obj, attr_name)
                        print('{} = {!r}'.format(name, value))
                    else:
                        try:
                            # convert and check the new value
                            parsed = ast.literal_eval(new_value)
                            value = attr_type(parsed)
                            if not attr_check(value):
                                msg = 'Invalid value "{}" for "{}"'
                                raise Exception(msg.format(new_value, name))
                        except Exception as e:
                            Dashboard.err(e)
                        else:
                            # set and redisplay
                            setattr(this.obj, attr_name, value)
                            this.dashboard.redisplay()
                prefix = self.prefix + ' ' + name
                doc = attribute.get('doc', 'This style is self-documenting')
                Dashboard.create_command(prefix, invoke, doc, False)

        def invoke(self, arg, from_tty):
            # print all the pairs
            for name, attribute in self.attributes.items():
                attr_name = attribute.get('name', name)
                value = getattr(self.obj, attr_name)
                print('{} = {!r}'.format(name, value))

# Base module ------------------------------------------------------------------

    # just a tag
    class Module():
        pass

# Default modules --------------------------------------------------------------

class Source(Dashboard.Module):
    """Show the program source code, if available."""

    def __init__(self):
        self.file_name = None
        self.source_lines = []

    def label(self):
        return 'Source'

    def lines(self):
        # try to fetch the current line (skip if no line information)
        sal = gdb.selected_frame().find_sal()
        current_line = sal.line
        if current_line == 0:
            return []
        # reload the source file if changed
        file_name = sal.symtab.fullname()
        if file_name != self.file_name:
            self.file_name = file_name
            try:
                with open(self.file_name) as source:
                    self.source_lines = source.readlines()
            except:
                msg = 'Cannot access "{}"'.format(self.file_name)
                return [ansi(msg, R.style_error)]
        # compute the line range
        start = max(current_line - 1 - self.context, 0)
        end = min(current_line - 1 + self.context, len(self.source_lines))
        # return the source code listing
        out = []
        number_format = '{{:>{}}}'.format(len(str(end)))
        for number, line in enumerate(self.source_lines[start:end], start + 1):
            if int(number) == current_line:
                line_format = ansi(number_format + ' {}', R.style_selected_1)
            else:
                line_format = ansi(number_format, R.style_low) + ' {}'
            out.append(line_format.format(number, line.rstrip('\n')))
        return out

    def set_context(self, arg):
        msg = 'expecting a positive integer'
        self.context = parse_value(arg, int, check_ge_zero, msg)

    def attributes(self):
        return {
            'context': {
                'doc': 'Number of context lines.',
                'default': 5,
                'type': int,
                'check': check_ge_zero
            }
        }

class Assembly(Dashboard.Module):
    """Show the disassembled code surrounding the program counter. The
instructions constituting the current statement are marked, if available."""

    def label(self):
        return 'Assembly'

    def lines(self):
        line_info = None
        frame = gdb.selected_frame()  # PC is here
        disassemble = frame.architecture().disassemble
        try:
            # try to fetch the function boundaries using the disassemble command
            output = run('disassemble').split('\n')
            start = int(output[1][3:].partition(' ')[0], 16)
            end = int(output[-3][3:].partition(' ')[0], 16)
            asm = disassemble(start, end_pc=end)
            # find the location of the PC
            pc_index = next(index for index, instr in enumerate(asm)
                            if instr['addr'] == frame.pc())
            start = max(pc_index - self.context, 0)
            end = pc_index + self.context + 1
            asm = asm[start:end]
            # if there are line information then use it, it may be that
            # line_info is not None but line_info.last is None
            line_info = gdb.find_pc_line(frame.pc())
            line_info = line_info if line_info.last else None
        except gdb.error:
            # if it is not possible (stripped binary) start from PC and end
            # after a fixed number of instructions
            asm = disassemble(frame.pc(), count=self.context)
        # fetch function start if available
        func_start = None
        if self.show_function and frame.name():
            try:
                value = gdb.parse_and_eval(frame.name()).address
                func_start = to_unsigned(value)
            except gdb.error:
                pass  # e.g., @plt
        # return the machine code
        max_length = max(instr['length'] for instr in asm)
        inferior = gdb.selected_inferior()
        out = []
        for index, instr in enumerate(asm):
            addr = instr['addr']
            length = instr['length']
            text = instr['asm']
            addr_str = format_address(addr)
            if self.show_opcodes:
                # fetch and format opcode
                region = inferior.read_memory(addr, length)
                opcodes = (' '.join('{:02x}'.format(ord(byte))
                                    for byte in region))
                opcodes += (max_length - len(region)) * 3 * ' ' + ' '
            else:
                opcodes = ''
            # compute the offset if available
            if self.show_function:
                if func_start:
                    max_offset = len(str(asm[-1]['addr'] - func_start))
                    offset = str(addr - func_start).ljust(max_offset)
                    func_info = '{}+{} '.format(frame.name(), offset)
                else:
                    func_info = '? '
            else:
                func_info = ''
            format_string = '{} {}{}{}'
            if addr == frame.pc():
                addr_str = ansi(addr_str, R.style_selected_1)
                opcodes = ansi(opcodes, R.style_selected_1)
                func_info = ansi(func_info, R.style_selected_1)
                text = ansi(text, R.style_selected_1)
            elif line_info and line_info.pc <= addr < line_info.last:
                addr_str = ansi(addr_str, R.style_selected_2)
                opcodes = ansi(opcodes, R.style_selected_2)
                func_info = ansi(func_info, R.style_selected_2)
                text = ansi(text, R.style_selected_2)
            else:
                addr_str = ansi(addr_str, R.style_low)
                func_info = ansi(func_info, R.style_low)
            out.append(format_string.format(addr_str, opcodes, func_info, text))
        return out

    def attributes(self):
        return {
            'context': {
                'doc': 'Number of context instructions.',
                'default': 3,
                'type': int,
                'check': check_ge_zero
            },
            'opcodes': {
                'doc': 'Opcodes visibility flag.',
                'default': False,
                'name': 'show_opcodes',
                'type': bool
            },
            'function': {
                'doc': 'Function information visibility flag.',
                'default': True,
                'name': 'show_function',
                'type': bool
            }
        }

class Stack(Dashboard.Module):
    """Show the current stack trace including the function name and the file
location, if available. Optionally list the frame arguments and locals too."""

    def label(self):
        return 'Stack'

    def lines(self):
        frames = []
        number = 0
        selected_index = 0
        frame = gdb.newest_frame()
        while frame:
            frame_lines = []
            # fetch frame info
            selected = (frame == gdb.selected_frame())
            if selected:
                selected_index = number
            style = R.style_selected_1 if selected else R.style_selected_2
            frame_id = ansi(str(number), style)
            info = Stack.get_pc_line(frame, style)
            frame_lines.append('[{}] {}'.format(frame_id, info))
            # fetch frame arguments and locals
            decorator = gdb.FrameDecorator.FrameDecorator(frame)
            if self.show_arguments:
                frame_args = decorator.frame_args()
                args_lines = self.fetch_frame_info(frame, frame_args, 'arg')
                if args_lines:
                    frame_lines.extend(args_lines)
                else:
                    frame_lines.append(ansi('(no arguments)', R.style_low))
            if self.show_locals:
                frame_locals = decorator.frame_locals()
                locals_lines = self.fetch_frame_info(frame, frame_locals, 'loc')
                if locals_lines:
                    frame_lines.extend(locals_lines)
                else:
                    frame_lines.append(ansi('(no locals)', R.style_low))
            # add frame
            frames.append(frame_lines)
            # next
            frame = frame.older()
            number += 1
        # format the output
        if not self.limit or self.limit >= len(frames):
            start = 0
            end = len(frames)
            more = False
        else:
            start = selected_index
            end = min(len(frames), start + self.limit)
            more = (len(frames) - start > self.limit)
        lines = []
        for frame_lines in frames[start:end]:
            lines.extend(frame_lines)
        # add the placeholder
        if more:
            lines.append('[{}]'.format(ansi('+', R.style_selected_2)))
        return lines

    def fetch_frame_info(self, frame, data, prefix):
        prefix = ansi(prefix, R.style_low)
        lines = []
        for elem in data or []:
            name = elem.sym
            value = elem.sym.value(frame)
            lines.append('{} {} = {}'.format(prefix, name, value))
        return lines

    @staticmethod
    def get_pc_line(frame, style):
        frame_pc = ansi(format_address(frame.pc()), style)
        info = 'from {}'.format(frame_pc)
        if frame.name():
            frame_name = ansi(frame.name(), style)
            try:
                # try to compute the offset relative to the current function
                value = gdb.parse_and_eval(frame.name()).address
                func_start = to_unsigned(value)
                offset = frame.pc() - func_start
                frame_name += '+' + ansi(str(offset), style)
            except gdb.error:
                pass  # e.g., @plt
            info += ' in {}()'.format(frame_name)
            sal = frame.find_sal()
            if sal.symtab:
                file_name = ansi(sal.symtab.filename, style)
                file_line = ansi(str(sal.line), style)
                info += ' at {}:{}'.format(file_name, file_line)
        return info

    def attributes(self):
        return {
            'limit': {
                'doc': 'Maximum number of displayed frames (0 means no limit).',
                'default': 2,
                'type': int,
                'check': check_ge_zero
            },
            'arguments': {
                'doc': 'Frame arguments visibility flag.',
                'default': True,
                'name': 'show_arguments',
                'type': bool
            },
            'locals': {
                'doc': 'Frame locals visibility flag.',
                'default': False,
                'name': 'show_locals',
                'type': bool
            }
        }

class History(Dashboard.Module):
    """List the last entries of the value history."""

    def label(self):
        return 'History'

    def lines(self):
        out = []
        # fetch last entries
        for i in range(-self.limit + 1, 1):
            try:
                value = gdb.history(i)
                value_id = ansi('$${}', R.style_low).format(abs(i))
                line = '{} = {}'.format(value_id, value)
                out.append(line)
            except gdb.error:
                continue
        return out

    def attributes(self):
        return {
            'limit': {
                'doc': 'Maximum number of values to show.',
                'default': 3,
                'type': int,
                'check': check_gt_zero
            }
        }

class Memory(Dashboard.Module):
    """Allow to inspect memory regions."""

    @staticmethod
    def format_byte(byte):
        # `type(byte) is bytes` in Python 3
        if byte.isspace():
            return ' '
        elif 0x20 < ord(byte) < 0x7e:
            return chr(ord(byte))
        else:
            return '.'

    @staticmethod
    def parse_as_address(expression):
        value = gdb.parse_and_eval(expression)
        return to_unsigned(value)

    def __init__(self):
        self.row_length = 16
        self.table = {}

    def format_memory(self, start, memory):
        out = []
        for i in range(0, len(memory), self.row_length):
            region = memory[i:i + self.row_length]
            pad = self.row_length - len(region)
            address = format_address(start + i)
            hexa = (' '.join('{:02x}'.format(ord(byte)) for byte in region))
            text = (''.join(Memory.format_byte(byte) for byte in region))
            out.append('{} {}{} {}{}'.format(ansi(address, R.style_low),
                                             hexa,
                                             ansi(pad * ' --', R.style_low),
                                             ansi(text, R.style_high),
                                             ansi(pad * '.', R.style_low)))
        return out

    def label(self):
        return 'Memory'

    def lines(self):
        out = []
        inferior = gdb.selected_inferior()
        for address, length in sorted(self.table.items()):
            try:
                memory = inferior.read_memory(address, length)
                out.extend(self.format_memory(address, memory))
            except gdb.error:
                msg = 'Cannot access {} bytes starting at {}'
                msg = msg.format(length, format_address(address))
                out.append(ansi(msg, R.style_error))
            out.append(divider())
        # drop last divider
        if out:
            del out[-1]
        return out

    def watch(self, arg):
        if arg:
            address, _, length = arg.partition(' ')
            address = Memory.parse_as_address(address)
            if length:
                length = Memory.parse_as_address(length)
            else:
                length = self.row_length
            self.table[address] = length
        else:
            raise Exception('Specify an address')

    def unwatch(self, arg):
        if arg:
            try:
                del self.table[Memory.parse_as_address(arg)]
            except KeyError:
                raise Exception('Memory region not watched')
        else:
            raise Exception('Specify an address')

    def clear(self, arg):
        self.table.clear()

    def commands(self):
        return {
            'watch': {
                'action': self.watch,
                'doc': 'Watch a memory region by address and length.\n'
                       'The length defaults to 16 byte.',
                'complete': gdb.COMPLETE_EXPRESSION
            },
            'unwatch': {
                'action': self.unwatch,
                'doc': 'Stop watching a memory region by address.',
                'complete': gdb.COMPLETE_EXPRESSION
            },
            'clear': {
                'action': self.clear,
                'doc': 'Clear all the watched regions.'
            }
        }

class Registers(Dashboard.Module):
    """Show the CPU registers and their values."""

    def __init__(self):
        self.table = {}

    def label(self):
        return 'Registers'

    def lines(self):
        # fetch registers status
        registers = []
        for reg_info in run('info registers').strip().split('\n'):
            # fetch register and update the table
            name = reg_info.split(None, 1)[0]
            value = gdb.parse_and_eval('${}'.format(name))
            string_value = self.format_value(value)
            changed = self.table and (self.table.get(name, '') != string_value)
            self.table[name] = string_value
            registers.append((name, string_value, changed))
        # split registers in rows and columns, each column is composed of name,
        # space, value and another trailing space which is skipped in the last
        # column (hence term_width + 1)
        max_name = max(len(name) for name, _, _ in registers)
        max_value = max(len(value) for _, value, _ in registers)
        max_width = max_name + max_value + 2
        per_line = int((Dashboard.term_width + 1) / max_width) or 1
        # redistribute extra space among columns
        extra = int((Dashboard.term_width + 1 -
                     max_width * per_line) / per_line)
        if per_line == 1:
            # center when there is only one column
            max_name += int(extra / 2)
            max_value += int(extra / 2)
        else:
            max_value += extra
        # format registers info
        partial = []
        for name, value, changed in registers:
            styled_name = ansi(name.rjust(max_name), R.style_low)
            value_style = R.style_selected_1 if changed else ''
            styled_value = ansi(value.ljust(max_value), value_style)
            partial.append(styled_name + ' ' + styled_value)
        out = []
        for i in range(0, len(partial), per_line):
            out.append(' '.join(partial[i:i + per_line]).rstrip())
        return out

    def format_value(self, value):
        try:
            if value.type.code in [gdb.TYPE_CODE_INT, gdb.TYPE_CODE_PTR]:
                int_value = to_unsigned(value, value.type.sizeof)
                value_format = '0x{{:0{}x}}'.format(2 * value.type.sizeof)
                return value_format.format(int_value)
        except (gdb.error, ValueError):
            # convert to unsigned but preserve code and flags information
            pass
        return str(value)

class Threads(Dashboard.Module):
    """List the currently available threads."""

    def label(self):
        return 'Threads'

    def lines(self):
        out = []
        selected_thread = gdb.selected_thread()
        selected_frame = gdb.selected_frame()
        for thread in gdb.Inferior.threads(gdb.selected_inferior()):
            is_selected = (thread.ptid == selected_thread.ptid)
            style = R.style_selected_1 if is_selected else R.style_selected_2
            number = ansi(str(thread.num), style)
            tid = ansi(str(thread.ptid[1] or thread.ptid[2]), style)
            info = '[{}] id {}'.format(number, tid)
            if thread.name:
                info += ' name {}'.format(ansi(thread.name, style))
            # switch thread to fetch frame info
            thread.switch()
            frame = gdb.newest_frame()
            info += ' ' + Stack.get_pc_line(frame, style)
            out.append(info)
        # restore thread and frame
        selected_thread.switch()
        selected_frame.select()
        return out

class Expressions(Dashboard.Module):
    """Watch user expressions."""

    def __init__(self):
        self.number = 1
        self.table = {}

    def label(self):
        return 'Expressions'

    def lines(self):
        out = []
        for number, expression in sorted(self.table.items()):
            try:
                value = gdb.parse_and_eval(expression)
            except gdb.error as e:
                value = ansi(e, R.style_error)
            number = ansi(number, R.style_selected_2)
            expression = ansi(expression, R.style_low)
            out.append('[{}] {} = {}'.format(number, expression, value))
        return out

    def watch(self, arg):
        if arg:
            self.table[self.number] = arg
            self.number += 1
        else:
            raise Exception('Specify an expression')

    def unwatch(self, arg):
        if arg:
            try:
                del self.table[int(arg)]
            except:
                raise Exception('Expression not watched')
        else:
            raise Exception('Specify an identifier')

    def clear(self, arg):
        self.table.clear()

    def commands(self):
        return {
            'watch': {
                'action': self.watch,
                'doc': 'Watch an expression.',
                'complete': gdb.COMPLETE_EXPRESSION
            },
            'unwatch': {
                'action': self.unwatch,
                'doc': 'Stop watching an expression by id.',
                'complete': gdb.COMPLETE_EXPRESSION
            },
            'clear': {
                'action': self.clear,
                'doc': 'Clear all the watched expressions.'
            }
        }

end

# Better GDB defaults ----------------------------------------------------------

set history save
set confirm off
set verbose off
set print pretty on
set print array off
set print array-indexes on
set python print-stack full

# Start ------------------------------------------------------------------------

python Dashboard.start()

# ------------------------------------------------------------------------------
# Copyright (c) 2015 Andrea Cardaci <cyrus.and@gmail.com>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
# ------------------------------------------------------------------------------
# vi:syntax=python
# Local Variables:
# mode: python
# End:
