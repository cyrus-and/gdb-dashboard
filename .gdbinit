python

import os
import subprocess

# Default values ---------------------------------------------------------------

class R():

    prompt = '{thread_status} '
    prompt_thread_available = '\[\e[1;35m\]>>>\[\e[0m\]'
    prompt_thread_not_available = '\[\e[1;30m\]>>>\[\e[0m\]'

    divider_fill_style = '36'
    divider_fill_char = '─'
    divider_label_style_on = '1;33'
    divider_label_style_off = '33'
    divider_label_skip = '3'
    divider_label_margin = '1'
    divider_label_align_right = '0'

    style_selected_1 = '1;32'
    style_selected_2 = '32'
    style_1 = '31'
    style_2 = '33'
    style_low = '1;30'
    style_high = '1;37'
    style_error = '31'

# Common -----------------------------------------------------------------------

def run(command):
    return gdb.execute(command, False, True)

def ansi(string, style):
    return '[{}m{}[0m'.format(style, string)

def err(string):
    print ansi(string, R.style_error)

def divider(label='', active=True):
    width = int(subprocess.check_output('echo $COLUMNS', shell=True))
    if label:
        if active:
            divider_label_style = R.divider_label_style_on
        else:
            divider_label_style = R.divider_label_style_off
        skip = int(R.divider_label_skip)
        margin = int(R.divider_label_margin)
        before = ansi(R.divider_fill_char * skip, R.divider_fill_style)
        middle = ansi(label, divider_label_style)
        after_length = width - len(label) - skip - 2 * margin
        after = ansi(R.divider_fill_char * after_length, R.divider_fill_style)
        if int(R.divider_label_align_right or '0'):
            before, after = after, before
        return ''.join([before, ' ' * margin, middle, ' ' * margin, after])
    else:
        return ansi(R.divider_fill_char * width, R.divider_fill_style)

def parse_on_off(arg, value):
    if arg == '':
        return not value
    elif arg == 'on':
        return True
    elif arg == 'off':
        return False
    else:
        msg = 'Wrong argument "{}"; expecting on/off or nothing'.format(arg)
        raise Exception(msg)

def parse_value(arg, conversion, check, msg):
    try:
        value = conversion(arg)
        if not check(value):
            raise ValueError
        return value
    except ValueError:
        raise Exception('Wrong argument "{}"; {}'.format(arg, msg))

# Dashboard --------------------------------------------------------------------

class Dashboard(gdb.Command):
    """Redisplay or control the dashboard visibility [on/off]"""

    @staticmethod
    def start():
        dashboard = Dashboard()
        Dashboard.set_custom_prompt(dashboard)
        # parse Python inits, load modules then parse GDB inits
        dashboard.init = True
        Dashboard.parse_inits(True)
        modules = Dashboard.get_modules()
        dashboard.load_modules(modules)
        Dashboard.parse_inits(False)
        dashboard.init = False

    @staticmethod
    def set_custom_prompt(dashboard):
        def custom_prompt(_):
            # render thread status indicator
            if dashboard.is_running():
                thread_status = R.prompt_thread_available
            else:
                thread_status = R.prompt_thread_not_available
            # build prompt
            prompt = R.prompt.format(thread_status=thread_status)
            return gdb.prompt.substitute_prompt(prompt)
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
    def create_command(name, invoke, doc, is_prefix=False):
        Class = type('', (gdb.Command,), {'invoke': invoke, '__doc__': doc})
        Class(name, gdb.COMMAND_USER, gdb.COMPLETE_NONE, is_prefix)

    def __init__(self):
        gdb.Command.__init__(self, 'dashboard',
                             gdb.COMMAND_USER, gdb.COMPLETE_NONE, True)
        self.enabled = True
        Dashboard.ModulesCommand(self)
        Dashboard.LayoutCommand(self)
        Dashboard.StyleCommand()
        # clear the screen on continue
        def display_header(_):
            if self.enabled and self.is_running():
                os.system('clear')
                print divider('Output/messages')
        gdb.events.cont.connect(display_header)
        # display the dashboard on stop
        def display_dashboard(_):
            if self.enabled and self.is_running():
                self.display()
        gdb.events.stop.connect(display_dashboard)

    def load_modules(self, modules):
        dashboard = self
        dupe_set = set()
        self.modules = []
        for module in modules:
            # skip duplicate modules
            if module in dupe_set:
                continue
            # instantiatie the module
            instance = module()
            info = {'name': module.__name__,
                    'enabled': True,
                    'instance': instance}
            self.modules.append(info)
            dupe_set.add(module)
            # create a GDB subcommand for it
            has_sub_commands = 'commands' in dir(instance)
            def invoke(self, arg, from_tty, info=info):
                try:
                    # set, reset or toggle visibility
                    enabled = parse_on_off(arg, info['enabled'])
                    changed = (info['enabled'] != enabled)
                    info['enabled'] = enabled
                    if changed:
                        dashboard.redisplay()
                except Exception as e:
                    err(e)
            doc_brief = 'Configure the {} module.'.format(module.__name__)
            doc_extended = 'Toggle or control the visibility [on/off]'
            doc = '{}\n{}'.format(doc_brief, doc_extended)
            prefix = 'dashboard {}'.format(module.__name__.lower())
            Dashboard.create_command(prefix, invoke, doc, has_sub_commands)
            # create subsubcommands, if any
            if has_sub_commands:
                for name, action, doc in instance.commands():
                    def invoke(self, arg, from_tty, action=action, info=info):
                        try:
                            if dashboard.init or info['enabled']:
                                action(arg)
                                dashboard.redisplay()
                            else:
                                err('Module disabled')
                        except Exception as e:
                            err(e)
                    sub_prefix = '{} {}'.format(prefix, name)
                    Dashboard.create_command(sub_prefix, invoke, doc)

    def redisplay(self):
        if not self.init:
            if self.is_running():
                os.system('clear')
                self.display()
            else:
                err('Is the target program running?')

    def is_running(self):
        return gdb.selected_inferior().pid != 0

    def display(self):
        lines = []
        for descr in self.modules:
            if not descr['enabled']:
                continue
            module = descr['instance']
            # active if more than zero lines
            module_lines = module.lines()
            lines.append(divider(module.label(), module_lines))
            lines.extend(module_lines)
        if len(lines) == 0:
            lines.append(divider('Error'))
            if len(self.modules) == 0:
                lines.append('No module loaded')
            else:
                lines.append('No module to display (see `help dashboard`)')
        lines.append(divider())
        # print without pagination
        run('set pagination off')
        print '\n'.join(lines)
        run('set pagination on')

    # GDB commands

    def invoke(self, arg, from_tty):
        if arg == '':
            self.redisplay()
        elif arg == 'on':
            self.redisplay()
            self.enabled = True
        elif arg == 'off':
            self.enabled = False
        else:
            err('Wrong argument "{}"; expecting on/off or nothing'.format(arg))

    class ModulesCommand(gdb.Command):
        """List all the currently loaded modules.
Modules are listed in the same order as they appear in the dashboard. Enabled
and disabled modules are properly marked."""

        def __init__(self, dashboard):
            gdb.Command.__init__(self, 'dashboard -modules', gdb.COMMAND_USER)
            self.dashboard = dashboard

        def invoke(self, arg, from_tty):
            for module in self.dashboard.modules:
                enabled = module['enabled']
                info = module['name']
                print ansi(info, R.style_high if enabled else R.style_low)

    class LayoutCommand(gdb.Command):
        """Set the dashboard layout by rearranging its modules.
Accepts a space-separated list of directive. Each directive is in the form
"[!]<module>". Modules in the list are placed in the dashboard in the same order
as they appear and those prefixed by "!" are visible by default. Omitted modules
are hidden and placed at the bottom in alphabetical order. Without arguments
disables all the modules."""

        def __init__(self, dashboard):
            gdb.Command.__init__(self, 'dashboard -layout', gdb.COMMAND_USER)
            self.dashboard = dashboard

        def invoke(self, arg, from_tty):
            modules = self.dashboard.modules
            directives = str(arg).split()
            # reset visibility
            for module in modules:
                module['enabled'] = False
            # move and enable the selected modules on top
            last = 0
            n_enabled = 0
            for directive in directives:
                # parse next directive
                enabled = (directive[0] == '!')
                name = directive[enabled:]
                try:
                    # it may actually start from last, but in this way repeated
                    # modules can be handler transparently and without error
                    todo = enumerate(modules[last:], start=last)
                    index = next(i for i, m in todo if name == m['name'])
                    modules[index]['enabled'] = enabled
                    modules.insert(last, modules.pop(index))
                    last += 1
                    n_enabled += enabled
                except StopIteration:
                    def find_module(x):
                        return x['name'] == name
                    first_part = modules[:last]
                    if len(filter(find_module, first_part)) == 0:
                        err('Cannot find module "{}"'.format(name))
                    else:
                        err('Module "{}" already specified'.format(name))
                    continue
            # redisplay the dashboard
            if not self.dashboard.init and self.dashboard.enabled and n_enabled:
                self.dashboard.redisplay()

    class StyleCommand(gdb.Command):
        """Set style attributes.
The first argument is the name and the second is the value. Omitting the value
corresponds to the empty string."""

        def __init__(self):
            gdb.Command.__init__(self, 'dashboard -style', gdb.COMMAND_USER)

        def invoke(self, arg, from_tty):
            name, _, value = arg.partition(' ')
            if name in dir(R):
                setattr(R, name, value)
            else:
                err('No style attribute "{}"'.format(name))

# Base module ------------------------------------------------------------------

    # just a tag
    class Module():
        pass

# Default modules --------------------------------------------------------------

class Source(Dashboard.Module):

    context = 10

    def label(self):
        return 'Source'

    def lines(self):
        # try to fetch the current line (skip if no line information)
        pc = gdb.newest_frame().pc()
        current_line = gdb.find_pc_line(pc).line
        if current_line == 0:
            return []
        # try to fetch the source code in the range
        start = max(current_line - Source.context, 1)
        end = current_line + Source.context
        source = run('list {},{}'.format(start, end)).split('\n')[:-1]
        # omit useless 'list' output when no source code is available
        if len(source) == 1:
            if not source[0].startswith(str(current_line) + '\t'):
                return []
        # return the source code
        out = []
        number_format = '{{:>{}}}'.format(len(str(end)))
        for line in source:
            number, _, code = line.partition('\t')
            if int(number) == current_line:
                line_format = ansi(number_format + ' {}', R.style_selected_1)
            else:
                line_format = ansi(number_format, R.style_low) + ' {}'
            out.append(line_format.format(number, code))
        return out

    def commands(self):
        def context(arg):
            msg = 'expecting a positive integer'
            Source.context = parse_value(arg, int, lambda x: x >= 0, msg)
        return [('context', context, 'Set the number of context lines.')]

class Assembly(Dashboard.Module):

    context = 5

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
            start = max(pc_index - Assembly.context, 0)
            end = pc_index + Assembly.context + 1
            asm = asm[start:end]
            # if there are line information then use it
            line_info = gdb.find_pc_line(frame.pc())
        except gdb.error:
            # if it is not possible (stripped binary) start from PC and end
            # after a fixed number of instructions
            asm = disassemble(frame.pc(), count=Assembly.context)
        # return the machine code
        out = []
        for index, instr in enumerate(asm):
            addr = instr['addr']
            mnem, _, ops = instr['asm'].partition('\t')
            addr_str = '0x{:016x}'.format(addr)
            format_string = '{} {}\t{}'
            asm_line = format_string.format(addr_str, mnem, ops)
            if addr == frame.pc():
                line = ansi(asm_line, R.style_selected_1)
            elif line_info and line_info.pc <= addr < line_info.last:
                line = ansi(asm_line, R.style_selected_2)
            else:
                styled_addr = ansi(addr_str, R.style_low)
                line = format_string.format(styled_addr, mnem, ops)
            out.append(line)
        return out

    def commands(self):
        def context(arg):
            msg = 'expecting a positive integer'
            Assembly.context = parse_value(arg, int, lambda x: x >= 0, msg)
        return [('context', context, 'Set the number of context instructions.')]

class Stack(Dashboard.Module):

    show_arguments = True
    show_locals = False

    def label(self):
        return 'Stack'

    def lines(self):
        lines = []
        number = 0
        frame = gdb.newest_frame()
        while frame:
            # fetch frame info
            selected = frame == gdb.selected_frame()
            style = R.style_selected_1 if selected else R.style_high
            frame_id = ansi(str(number), style)
            frame_pc = ansi('0x{:016x}', R.style_high).format(frame.pc())
            info = '[{}] from {}'.format(frame_id, frame_pc)
            if frame.name():
                frame_name = ansi(frame.name(), R.style_high)
                info += ' in {}()'.format(frame_name)
                sal = frame.find_sal()
                if sal.symtab:
                    file_name = ansi(sal.symtab.filename, R.style_high)
                    file_line = ansi(str(sal.line), R.style_high)
                    info += ' at {}:{}'.format(file_name, file_line)
            lines.append(info)
            # fetch frame arguments and locals
            decorator = gdb.FrameDecorator.FrameDecorator(frame)
            if Stack.show_arguments:
                frame_args = decorator.frame_args()
                lines += self.fetch_frame_info(frame, frame_args, R.style_1)
            if Stack.show_locals:
                frame_locals = decorator.frame_locals()
                lines += self.fetch_frame_info(frame, frame_locals, R.style_2)
            # next
            frame = frame.older()
            number += 1
        return lines

    def fetch_frame_info(self, frame, data, style):
        lines = []
        for elem in data or []:
            name = ansi(elem.sym, style)
            value = elem.sym.value(frame)
            lines.append('{} = {}'.format(name, value))
        return lines

    def commands(self):
        def show_arguments(arg):
            Stack.show_arguments = parse_on_off(arg, Stack.show_arguments)
        def show_locals(arg):
            Stack.show_locals = parse_on_off(arg, Stack.show_locals)
        return [('arguments', show_arguments,
                 'Toggle or control frame arguments visibility [on/off]'),
                ('locals', show_locals,
                 'Toggle or control frame locals visibility [on/off]')]

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
# vi:syntax=python
# Local Variables:
# mode: python
# End:
