python

# GDB dashboard - Modular visual interface for GDB in Python.
#
# https://github.com/cyrus-and/gdb-dashboard

# License ----------------------------------------------------------------------

# Copyright (c) 2015-2022 Andrea Cardaci <cyrus.and@gmail.com>
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

# Imports ----------------------------------------------------------------------

import ast
import io
import itertools
import math
import os
import re
import struct
import traceback

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
            'syntax_highlighting': {
                'doc': '''Pygments style to use for syntax highlighting.

Using an empty string (or a name not in the list) disables this feature. The
list of all the available styles can be obtained with (from GDB itself):

    python from pygments.styles import *
    python for style in get_all_styles(): print(style)''',
                'default': 'monokai'
            },
            'discard_scrollback': {
                'doc': '''Discard the scrollback buffer at each redraw.

This makes scrolling less confusing by discarding the previously printed
dashboards but only works with certain terminals.''',
                'default': True,
                'type': bool
            },
            # values formatting
            'compact_values': {
                'doc': 'Display complex objects in a single line.',
                'default': True,
                'type': bool
            },
            'max_value_length': {
                'doc': 'Maximum length of displayed values before truncation.',
                'default': 100,
                'type': int
            },
            'value_truncation_string': {
                'doc': 'String to use to mark value truncation.',
                'default': '…',
            },
            'dereference': {
                'doc': 'Annotate pointers with the pointed value.',
                'default': True,
                'type': bool
            },
            # prompt
            'prompt': {
                'doc': '''GDB prompt.

This value is used as a Python format string where `{status}` is expanded with
the substitution of either `prompt_running` or `prompt_not_running` attributes,
according to the target program status. The resulting string must be a valid GDB
prompt, see the command `python print(gdb.prompt.prompt_help())`''',
                'default': '{status}'
            },
            'prompt_running': {
                'doc': '''Define the value of `{status}` when the target program is running.

See the `prompt` attribute. This value is used as a Python format string where
`{pid}` is expanded with the process identifier of the target program.''',
                'default': '\[\e[1;35m\]>>>\[\e[0m\]'
            },
            'prompt_not_running': {
                'doc': '''Define the value of `{status}` when the target program is running.

See the `prompt` attribute. This value is used as a Python format string.''',
                'default': '\[\e[90m\]>>>\[\e[0m\]'
            },
            # divider
            'omit_divider': {
                'doc': 'Omit the divider in external outputs when only one module is displayed.',
                'default': False,
                'type': bool
            },
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
                'default': '90'
            },
            'divider_label_style_on_primary': {
                'doc': 'Label style for non-empty primary dividers',
                'default': '1;33'
            },
            'divider_label_style_on_secondary': {
                'doc': 'Label style for non-empty secondary dividers',
                'default': '1;37'
            },
            'divider_label_style_off_primary': {
                'doc': 'Label style for empty primary dividers',
                'default': '33'
            },
            'divider_label_style_off_secondary': {
                'doc': 'Label style for empty secondary dividers',
                'default': '90'
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
                'default': '90'
            },
            'style_high': {
                'default': '1;37'
            },
            'style_error': {
                'default': '31'
            },
            'style_critical': {
                'default': '0;41'
            }
        }

# Common -----------------------------------------------------------------------

class Beautifier():

    def __init__(self, hint, tab_size=4):
        self.tab_spaces = ' ' * tab_size if tab_size else None
        self.active = False
        if not R.ansi or not R.syntax_highlighting:
            return
        # attempt to set up Pygments
        try:
            import pygments
            from pygments.lexers import GasLexer, NasmLexer
            from pygments.formatters import Terminal256Formatter
            if hint == 'att':
                self.lexer = GasLexer()
            elif hint == 'intel':
                self.lexer = NasmLexer()
            else:
                from pygments.lexers import get_lexer_for_filename
                self.lexer = get_lexer_for_filename(hint, stripnl=False)
            self.formatter = Terminal256Formatter(style=R.syntax_highlighting)
            self.active = True
        except ImportError:
            # Pygments not available
            pass
        except pygments.util.ClassNotFound:
            # no lexer for this file or invalid style
            pass

    def process(self, source):
        # convert tabs if requested
        if self.tab_spaces:
            source = source.replace('\t', self.tab_spaces)
        if self.active:
            import pygments
            source = pygments.highlight(source, self.lexer, self.formatter)
        return source.rstrip('\n')

def run(command):
    return gdb.execute(command, to_string=True)

def ansi(string, style):
    if R.ansi:
        return '\x1b[{}m{}\x1b[0m'.format(style, string)
    else:
        return string

def divider(width, label='', primary=False, active=True):
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
    mask = (2 ** (size * 8)) - 1
    return int(value.cast(gdb.Value(mask).type)) & mask

def to_string(value):
    # attempt to convert an inferior value to string; OK when (Python 3 ||
    # simple ASCII); otherwise (Python 2.7 && not ASCII) encode the string as
    # utf8
    try:
        value_string = str(value)
    except UnicodeEncodeError:
        value_string = unicode(value).encode('utf8')
    except gdb.error as e:
        value_string = ansi(e, R.style_error)
    return value_string

def format_address(address):
    pointer_size = gdb.parse_and_eval('$pc').type.sizeof
    return ('0x{{:0{}x}}').format(pointer_size * 2).format(address)

def format_value(value, compact=None):
    # format references as referenced values
    # (TYPE_CODE_RVALUE_REF is not supported by old GDB)
    if value.type.code in (getattr(gdb, 'TYPE_CODE_REF', None),
                           getattr(gdb, 'TYPE_CODE_RVALUE_REF', None)):
        try:
            value = value.referenced_value()
        except gdb.error as e:
            return ansi(e, R.style_error)
    # format the value
    out = to_string(value)
    # dereference up to the actual value if requested
    if R.dereference and value.type.code == gdb.TYPE_CODE_PTR:
        while value.type.code == gdb.TYPE_CODE_PTR:
            try:
                value = value.dereference()
            except gdb.error as e:
                break
        else:
            formatted = to_string(value)
            out += '{} {}'.format(ansi(':', R.style_low), formatted)
    # compact the value
    if compact is not None and compact or R.compact_values:
        out = re.sub(r'$\s*', '', out, flags=re.MULTILINE)
    # truncate the value
    if R.max_value_length > 0 and len(out) > R.max_value_length:
        out = out[0:R.max_value_length] + ansi(R.value_truncation_string, R.style_critical)
    return out

# XXX parsing the output of `info breakpoints` is apparently the best option
# right now, see: https://sourceware.org/bugzilla/show_bug.cgi?id=18385
# XXX GDB version 7.11 (quire recent) does not have the pending field, so
# fall back to the parsed information
def fetch_breakpoints(watchpoints=False, pending=False):
    # fetch breakpoints addresses
    parsed_breakpoints = dict()
    catch_what_regex = re.compile(r'([^,]+".*")?[^,]*')
    for line in run('info breakpoints').split('\n'):
        # just keep numbered lines
        if not line or not line[0].isdigit():
            continue
        # extract breakpoint number, address and pending status
        fields = line.split()
        number = int(fields[0].split('.')[0])
        try:
            if len(fields) >= 5 and fields[1] == 'breakpoint':
                # multiple breakpoints have no address yet
                is_pending = fields[4] == '<PENDING>'
                is_multiple = fields[4] == '<MULTIPLE>'
                address = None if is_multiple or is_pending else int(fields[4], 16)
                is_enabled = fields[3] == 'y'
                address_info = address, is_enabled
                parsed_breakpoints[number] = [address_info], is_pending, ''
            elif len(fields) >= 5 and fields[1] == 'catchpoint':
                # only take before comma, but ignore commas in quotes
                what = catch_what_regex.search(' '.join(fields[4:]))[0].strip()
                parsed_breakpoints[number] = [], False, what
            elif len(fields) >= 3 and number in parsed_breakpoints:
                # add this address to the list of multiple locations
                address = int(fields[2], 16)
                is_enabled = fields[1] == 'y'
                address_info = address, is_enabled
                parsed_breakpoints[number][0].append(address_info)
            else:
                # watchpoints
                parsed_breakpoints[number] = [], False, ''
        except ValueError:
            pass
    # fetch breakpoints from the API and complement with address and source
    # information
    breakpoints = []
    # XXX in older versions gdb.breakpoints() returns None
    for gdb_breakpoint in gdb.breakpoints() or []:
        # skip internal breakpoints
        if gdb_breakpoint.number < 0:
            continue
        addresses, is_pending, what = parsed_breakpoints[gdb_breakpoint.number]
        is_pending = getattr(gdb_breakpoint, 'pending', is_pending)
        if not pending and is_pending:
            continue
        if not watchpoints and gdb_breakpoint.type != gdb.BP_BREAKPOINT:
            continue
        # add useful fields to the object
        breakpoint = dict()
        breakpoint['number'] = gdb_breakpoint.number
        breakpoint['type'] = gdb_breakpoint.type
        breakpoint['enabled'] = gdb_breakpoint.enabled
        breakpoint['location'] = gdb_breakpoint.location
        breakpoint['expression'] = gdb_breakpoint.expression
        breakpoint['condition'] = gdb_breakpoint.condition
        breakpoint['temporary'] = gdb_breakpoint.temporary
        breakpoint['hit_count'] = gdb_breakpoint.hit_count
        breakpoint['pending'] = is_pending
        breakpoint['what'] = what
        # add addresses and source information
        breakpoint['addresses'] = []
        for address, is_enabled in addresses:
            if address:
                sal = gdb.find_pc_line(address)
            breakpoint['addresses'].append({
                'address': address,
                'enabled': is_enabled,
                'file_name': sal.symtab.filename if address and sal.symtab else None,
                'file_line': sal.line if address else None
            })
        breakpoints.append(breakpoint)
    return breakpoints

# Dashboard --------------------------------------------------------------------

class Dashboard(gdb.Command):
    '''Redisplay the dashboard.'''

    def __init__(self):
        gdb.Command.__init__(self, 'dashboard', gdb.COMMAND_USER, gdb.COMPLETE_NONE, True)
        # setup subcommands
        Dashboard.ConfigurationCommand(self)
        Dashboard.OutputCommand(self)
        Dashboard.EnabledCommand(self)
        Dashboard.LayoutCommand(self)
        # setup style commands
        Dashboard.StyleCommand(self, 'dashboard', R, R.attributes())
        # main terminal
        self.output = None
        # used to inhibit redisplays during init parsing
        self.inhibited = None
        # enabled by default
        self.enabled = None
        self.enable()

    def on_continue(self, _):
        # try to contain the GDB messages in a specified area unless the
        # dashboard is printed to a separate file (dashboard -output ...)
        # or there are no modules to display in the main terminal
        enabled_modules = list(filter(lambda m: not m.output and m.enabled, self.modules))
        if self.is_running() and not self.output and len(enabled_modules) > 0:
            width, _ = Dashboard.get_term_size()
            gdb.write(Dashboard.clear_screen())
            gdb.write(divider(width, 'Output/messages', True))
            gdb.write('\n')
            gdb.flush()

    def on_stop(self, _):
        if self.is_running():
            self.render(clear_screen=False)

    def on_exit(self, _):
        if not self.is_running():
            return
        # collect all the outputs
        outputs = set()
        outputs.add(self.output)
        outputs.update(module.output for module in self.modules)
        outputs.remove(None)
        # reset the terminal status
        for output in outputs:
            try:
                with open(output, 'w') as fs:
                    fs.write(Dashboard.reset_terminal())
            except:
                # skip cleanup for invalid outputs
                pass

    def enable(self):
        if self.enabled:
            return
        self.enabled = True
        # setup events
        gdb.events.cont.connect(self.on_continue)
        gdb.events.stop.connect(self.on_stop)
        gdb.events.exited.connect(self.on_exit)

    def disable(self):
        if not self.enabled:
            return
        self.enabled = False
        # setup events
        gdb.events.cont.disconnect(self.on_continue)
        gdb.events.stop.disconnect(self.on_stop)
        gdb.events.exited.disconnect(self.on_exit)

    def load_modules(self, modules):
        self.modules = []
        for module in modules:
            info = Dashboard.ModuleInfo(self, module)
            self.modules.append(info)

    def redisplay(self, style_changed=False):
        # manually redisplay the dashboard
        if self.is_running() and not self.inhibited:
            self.render(True, style_changed)

    def inferior_pid(self):
        return gdb.selected_inferior().pid

    def is_running(self):
        return self.inferior_pid() != 0

    def render(self, clear_screen, style_changed=False):
        # fetch module content and info
        all_disabled = True
        display_map = dict()
        for module in self.modules:
            # fall back to the global value
            output = module.output or self.output
            # add the instance or None if disabled
            if module.enabled:
                all_disabled = False
                instance = module.instance
            else:
                instance = None
            display_map.setdefault(output, []).append(instance)
        # process each display info
        for output, instances in display_map.items():
            try:
                buf = ''
                # use GDB stream by default
                fs = None
                if output:
                    fs = open(output, 'w')
                    fd = fs.fileno()
                    fs.write(Dashboard.setup_terminal())
                else:
                    fs = gdb
                    fd = 1  # stdout
                # get the terminal size (default main terminal if either the
                # output is not a file)
                try:
                    width, height = Dashboard.get_term_size(fd)
                except:
                    width, height = Dashboard.get_term_size()
                # clear the "screen" if requested for the main terminal,
                # auxiliary terminals are always cleared
                if fs is not gdb or clear_screen:
                    buf += Dashboard.clear_screen()
                # show message if all the modules in this output are disabled
                if not any(instances):
                    # skip the main terminal
                    if fs is gdb:
                        continue
                    # write the error message
                    buf += divider(width, 'Warning', True)
                    buf += '\n'
                    if self.modules:
                        buf += 'No module to display (see `dashboard -layout`)'
                    else:
                        buf += 'No module loaded'
                    buf += '\n'
                    fs.write(buf)
                    continue
                # process all the modules for that output
                for n, instance in enumerate(instances, 1):
                    # skip disabled modules
                    if not instance:
                        continue
                    try:
                        # ask the module to generate the content
                        lines = instance.lines(width, height, style_changed)
                    except Exception as e:
                        # allow to continue on exceptions in modules
                        stacktrace = traceback.format_exc().strip()
                        lines = [ansi(stacktrace, R.style_error)]
                    # create the divider if needed
                    div = []
                    if not R.omit_divider or len(instances) > 1 or fs is gdb:
                        div = [divider(width, instance.label(), True, lines)]
                    # write the data
                    buf += '\n'.join(div + lines)
                    # write the newline for all but last unless main terminal
                    if n != len(instances) or fs is gdb:
                        buf += '\n'
                # write the final newline and the terminator only if it is the
                # main terminal to allow the prompt to display correctly (unless
                # there are no modules to display)
                if fs is gdb and not all_disabled:
                    buf += divider(width, primary=True)
                    buf += '\n'
                fs.write(buf)
            except Exception as e:
                cause = traceback.format_exc().strip()
                Dashboard.err('Cannot write the dashboard\n{}'.format(cause))
            finally:
                # don't close gdb stream
                if fs and fs is not gdb:
                    fs.close()

# Utility methods --------------------------------------------------------------

    @staticmethod
    def start():
        # save the instance for customization convenience
        global dashboard
        # initialize the dashboard
        dashboard = Dashboard()
        Dashboard.set_custom_prompt(dashboard)
        # parse Python inits, load modules then parse GDB inits
        dashboard.inhibited = True
        Dashboard.parse_inits(True)
        modules = Dashboard.get_modules()
        dashboard.load_modules(modules)
        Dashboard.parse_inits(False)
        dashboard.inhibited = False
        # GDB overrides
        run('set pagination off')
        # display if possible (program running and not explicitly disabled by
        # some configuration file)
        if dashboard.enabled:
            dashboard.redisplay()

    @staticmethod
    def get_term_size(fd=1):  # defaults to the main terminal
        try:
            if sys.platform == 'win32':
                import curses
                # XXX always neglects the fd parameter
                height, width = curses.initscr().getmaxyx()
                curses.endwin()
                return int(width), int(height)
            else:
                import termios
                import fcntl
                # first 2 shorts (4 byte) of struct winsize
                raw = fcntl.ioctl(fd, termios.TIOCGWINSZ, ' ' * 4)
                height, width = struct.unpack('hh', raw)
                return int(width), int(height)
        except (ImportError, OSError):
            # this happens when no curses library is found on windows or when
            # the terminal is not properly configured
            return 80, 24  # hardcoded fallback value

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
        # paths where the .gdbinit.d directory might be
        search_paths = [
            '/etc/gdb-dashboard',
            '{}/gdb-dashboard'.format(os.getenv('XDG_CONFIG_HOME', '~/.config')),
            '~/Library/Preferences/gdb-dashboard',
            '~/.gdbinit.d'
        ]
        # expand the tilde and walk the paths
        inits_dirs = (os.walk(os.path.expanduser(path)) for path in search_paths)
        # process all the init files in order
        for root, dirs, files in itertools.chain.from_iterable(inits_dirs):
            dirs.sort()
            for init in sorted(files):
                path = os.path.join(root, init)
                _, ext = os.path.splitext(path)
                # either load Python files or GDB
                if python == (ext == '.py'):
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
        return filter(lambda candidate: candidate.startswith(word), candidates)

    @staticmethod
    def parse_arg(arg):
        # encode unicode GDB command arguments as utf8 in Python 2.7
        if type(arg) is not str:
            arg = arg.encode('utf8')
        return arg

    @staticmethod
    def clear_screen():
        # ANSI: move the cursor to top-left corner and clear the screen
        # (optionally also clear the scrollback buffer if supported by the
        # terminal)
        return '\x1b[H\x1b[J' + '\x1b[3J' if R.discard_scrollback else ''

    @staticmethod
    def setup_terminal():
        # ANSI: enable alternative screen buffer and hide cursor
        return '\x1b[?1049h\x1b[?25l'

    @staticmethod
    def reset_terminal():
        # ANSI: disable alternative screen buffer and show cursor
        return '\x1b[?1049l\x1b[?25h'

# Module descriptor ------------------------------------------------------------

    class ModuleInfo:

        def __init__(self, dashboard, module):
            self.name = module.__name__.lower()  # from class to module name
            self.enabled = True
            self.output = None  # value from the dashboard by default
            self.instance = module()
            self.doc = self.instance.__doc__ or '(no documentation)'
            self.prefix = 'dashboard {}'.format(self.name)
            # add GDB commands
            self.add_main_command(dashboard)
            self.add_output_command(dashboard)
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
            doc_brief = 'Configure the {} module, with no arguments toggles its visibility.'.format(self.name)
            doc = '{}\n\n{}'.format(doc_brief, self.doc)
            Dashboard.create_command(self.prefix, invoke, doc, True)

        def add_output_command(self, dashboard):
            Dashboard.OutputCommand(dashboard, self.prefix, self)

        def add_style_command(self, dashboard):
            Dashboard.StyleCommand(dashboard, self.prefix, self.instance, self.instance.attributes())

        def add_subcommands(self, dashboard):
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

    # handler for the `dashboard` command itself
    def invoke(self, arg, from_tty):
        arg = Dashboard.parse_arg(arg)
        # show messages for checks in redisplay
        if arg != '':
            Dashboard.err('Wrong argument "{}"'.format(arg))
        elif not self.is_running():
            Dashboard.err('Is the target program running?')
        else:
            self.redisplay()

    class ConfigurationCommand(gdb.Command):
        '''Dump or save the dashboard configuration.

With an optional argument the configuration will be written to the specified
file.

This command allows to configure the dashboard live then make the changes
permanent, for example:

    dashboard -configuration ~/.gdbinit.d/init

At startup the `~/.gdbinit.d/` directory tree is walked and files are evaluated
in alphabetical order but giving priority to Python files. This is where user
configuration files must be placed.'''

        def __init__(self, dashboard):
            gdb.Command.__init__(self, 'dashboard -configuration',
                                 gdb.COMMAND_USER, gdb.COMPLETE_FILENAME)
            self.dashboard = dashboard

        def invoke(self, arg, from_tty):
            arg = Dashboard.parse_arg(arg)
            if arg:
                with open(os.path.expanduser(arg), 'w') as fs:
                    fs.write('# auto generated by GDB dashboard\n\n')
                    self.dump(fs)
            self.dump(gdb)

        def dump(self, fs):
            # dump layout
            self.dump_layout(fs)
            # dump styles
            self.dump_style(fs, R)
            for module in self.dashboard.modules:
                self.dump_style(fs, module.instance, module.prefix)
            # dump outputs
            self.dump_output(fs, self.dashboard)
            for module in self.dashboard.modules:
                self.dump_output(fs, module, module.prefix)

        def dump_layout(self, fs):
            layout = ['dashboard -layout']
            for module in self.dashboard.modules:
                mark = '' if module.enabled else '!'
                layout.append('{}{}'.format(mark, module.name))
            fs.write(' '.join(layout))
            fs.write('\n')

        def dump_style(self, fs, obj, prefix='dashboard'):
            attributes = getattr(obj, 'attributes', lambda: dict())()
            for name, attribute in attributes.items():
                real_name = attribute.get('name', name)
                default = attribute.get('default')
                value = getattr(obj, real_name)
                if value != default:
                    fs.write('{} -style {} {!r}\n'.format(prefix, name, value))

        def dump_output(self, fs, obj, prefix='dashboard'):
            output = getattr(obj, 'output')
            if output:
                fs.write('{} -output {}\n'.format(prefix, output))

    class OutputCommand(gdb.Command):
        '''Set the output file/TTY for the whole dashboard or single modules.

The dashboard/module will be written to the specified file, which will be
created if it does not exist. If the specified file identifies a terminal then
its geometry will be used, otherwise it falls back to the geometry of the main
GDB terminal.

When invoked without argument on the dashboard, the output/messages and modules
which do not specify an output themselves will be printed on standard output
(default).

When invoked without argument on a module, it will be printed where the
dashboard will be printed.

An overview of all the outputs can be obtained with the `dashboard -layout`
command.'''

        def __init__(self, dashboard, prefix=None, obj=None):
            if not prefix:
                prefix = 'dashboard'
            if not obj:
                obj = dashboard
            prefix = prefix + ' -output'
            gdb.Command.__init__(self, prefix, gdb.COMMAND_USER, gdb.COMPLETE_FILENAME)
            self.dashboard = dashboard
            self.obj = obj  # None means the dashboard itself

        def invoke(self, arg, from_tty):
            arg = Dashboard.parse_arg(arg)
            # reset the terminal status
            if self.obj.output:
                try:
                    with open(self.obj.output, 'w') as fs:
                        fs.write(Dashboard.reset_terminal())
                except:
                    # just do nothing if the file is not writable
                    pass
            # set or open the output file
            if arg == '':
                self.obj.output = None
            else:
                self.obj.output = arg
            # redisplay the dashboard in the new output
            self.dashboard.redisplay()

    class EnabledCommand(gdb.Command):
        '''Enable or disable the dashboard.

The current status is printed if no argument is present.'''

        def __init__(self, dashboard):
            gdb.Command.__init__(self, 'dashboard -enabled', gdb.COMMAND_USER)
            self.dashboard = dashboard

        def invoke(self, arg, from_tty):
            arg = Dashboard.parse_arg(arg)
            if arg == '':
                status = 'enabled' if self.dashboard.enabled else 'disabled'
                print('The dashboard is {}'.format(status))
            elif arg == 'on':
                self.dashboard.enable()
                self.dashboard.redisplay()
            elif arg == 'off':
                self.dashboard.disable()
            else:
                msg = 'Wrong argument "{}"; expecting "on" or "off"'
                Dashboard.err(msg.format(arg))

        def complete(self, text, word):
            return Dashboard.complete(word, ['on', 'off'])

    class LayoutCommand(gdb.Command):
        '''Set or show the dashboard layout.

Accepts a space-separated list of directive. Each directive is in the form
"[!]<module>". Modules in the list are placed in the dashboard in the same order
as they appear and those prefixed by "!" are disabled by default. Omitted
modules are hidden and placed at the bottom in alphabetical order.

Without arguments the current layout is shown where the first line uses the same
form expected by the input while the remaining depict the current status of
output files.

Passing `!` as a single argument resets the dashboard original layout.'''

        def __init__(self, dashboard):
            gdb.Command.__init__(self, 'dashboard -layout', gdb.COMMAND_USER)
            self.dashboard = dashboard

        def invoke(self, arg, from_tty):
            arg = Dashboard.parse_arg(arg)
            directives = str(arg).split()
            if directives:
                # apply the layout
                if directives == ['!']:
                    self.reset()
                else:
                    if not self.layout(directives):
                        return  # in case of errors
                # redisplay or otherwise notify
                if from_tty:
                    if self.dashboard.is_running():
                        self.dashboard.redisplay()
                    else:
                        self.show()
            else:
                self.show()

        def reset(self):
            modules = self.dashboard.modules
            modules.sort(key=lambda module: module.name)
            for module in modules:
                module.enabled = True

        def show(self):
            global_str = 'Dashboard'
            default = '(default TTY)'
            max_name_len = max(len(module.name) for module in self.dashboard.modules)
            max_name_len = max(max_name_len, len(global_str))
            fmt = '{{}}{{:{}s}}{{}}'.format(max_name_len + 2)
            print((fmt + '\n').format(' ', global_str, self.dashboard.output or default))
            for module in self.dashboard.modules:
                mark = ' ' if module.enabled else '!'
                style = R.style_high if module.enabled else R.style_low
                line = fmt.format(mark, module.name, module.output or default)
                print(ansi(line, style))

        def layout(self, directives):
            modules = self.dashboard.modules
            # parse and check directives
            parsed_directives = []
            selected_modules = set()
            for directive in directives:
                enabled = (directive[0] != '!')
                name = directive[not enabled:]
                if name in selected_modules:
                    Dashboard.err('Module "{}" already set'.format(name))
                    return False
                if next((False for module in modules if module.name == name), True):
                    Dashboard.err('Cannot find module "{}"'.format(name))
                    return False
                parsed_directives.append((name, enabled))
                selected_modules.add(name)
            # reset visibility
            for module in modules:
                module.enabled = False
            # move and enable the selected modules on top
            last = 0
            for name, enabled in parsed_directives:
                todo = enumerate(modules[last:], start=last)
                index = next(index for index, module in todo if name == module.name)
                modules[index].enabled = enabled
                modules.insert(last, modules.pop(index))
                last += 1
            return True

        def complete(self, text, word):
            all_modules = (m.name for m in self.dashboard.modules)
            return Dashboard.complete(word, all_modules)

    class StyleCommand(gdb.Command):
        '''Access the stylable attributes.

Without arguments print all the stylable attributes.

When only the name is specified show the current value.

With name and value set the stylable attribute. Values are parsed as Python
literals and converted to the proper type. '''

        def __init__(self, dashboard, prefix, obj, attributes):
            self.prefix = prefix + ' -style'
            gdb.Command.__init__(self, self.prefix, gdb.COMMAND_USER, gdb.COMPLETE_NONE, True)
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
                def invoke(self, arg, from_tty,
                           name=name,
                           attr_name=attr_name,
                           attr_type=attr_type,
                           attr_check=attr_check):
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
                            this.dashboard.redisplay(True)
                prefix = self.prefix + ' ' + name
                doc = attribute.get('doc', 'This style is self-documenting')
                Dashboard.create_command(prefix, invoke, doc, False)

        def invoke(self, arg, from_tty):
            # an argument here means that the provided attribute is invalid
            if arg:
                Dashboard.err('Invalid argument "{}"'.format(arg))
                return
            # print all the pairs
            for name, attribute in self.attributes.items():
                attr_name = attribute.get('name', name)
                value = getattr(self.obj, attr_name)
                print('{} = {!r}'.format(name, value))

# Base module ------------------------------------------------------------------

    # just a tag
    class Module():
        '''Base class for GDB dashboard modules.

        Modules are instantiated once at initialization time and kept during the
        whole the GDB session.

        The name of a module is automatically obtained by the class name.

        Optionally, a module may include a description which will appear in the
        GDB help system by specifying a Python docstring for the class. By
        convention the first line should contain a brief description.'''

        def label(self):
            '''Return the module label which will appear in the divider.'''
            pass

        def lines(self, term_width, term_height, style_changed):
            '''Return a list of strings which will form the module content.

            When a module is temporarily unable to produce its content, it
            should return an empty list; its divider will then use the styles
            with the "off" qualifier.

            term_width and term_height are the dimension of the terminal where
            this module will be displayed. If `style_changed` is `True` then
            some attributes have changed since the last time so the
            implementation may want to update its status.'''
            pass

        def attributes(self):
            '''Return the dictionary of available attributes.

            The key is the attribute name and the value is another dictionary
            with items:

            - `default` is the initial value for this attribute;

            - `doc` is the optional documentation of this attribute which will
              appear in the GDB help system;

            - `name` is the name of the attribute of the Python object (defaults
              to the key value);

            - `type` is the Python type of this attribute defaulting to the
              `str` type, it is used to coerce the value passed as an argument
              to the proper type, or raise an exception;

            - `check` is an optional control callback which accept the coerced
              value and returns `True` if the value satisfies the constraint and
              `False` otherwise.

            Those attributes can be accessed from the implementation using
            instance variables named `name`.'''
            return {}

        def commands(self):
            '''Return the dictionary of available commands.

            The key is the attribute name and the value is another dictionary
            with items:

            - `action` is the callback to be executed which accepts the raw
              input string from the GDB prompt, exceptions in these functions
              will be shown automatically to the user;

            - `doc` is the documentation of this command which will appear in
              the GDB help system;

            - `completion` is the optional completion policy, one of the
              `gdb.COMPLETE_*` constants defined in the GDB reference manual
              (https://sourceware.org/gdb/onlinedocs/gdb/Commands-In-Python.html).'''
            return {}

# Default modules --------------------------------------------------------------

class Source(Dashboard.Module):
    '''Show the program source code, if available.'''

    def __init__(self):
        self.file_name = None
        self.source_lines = []
        self.ts = None
        self.highlighted = False
        self.offset = 0

    def label(self):
        label = 'Source'
        if self.show_path and self.file_name:
            label += ': {}'.format(self.file_name)
        return label

    def lines(self, term_width, term_height, style_changed):
        # skip if the current thread is not stopped
        if not gdb.selected_thread().is_stopped():
            return []
        # try to fetch the current line (skip if no line information)
        sal = gdb.selected_frame().find_sal()
        current_line = sal.line
        if current_line == 0:
            self.file_name = None
            return []
        # try to lookup the source file
        candidates = [
            sal.symtab.fullname(),
            sal.symtab.filename,
            # XXX GDB also uses absolute filename but it is harder to implement
            # properly and IMHO useless
            os.path.basename(sal.symtab.filename)]
        for candidate in candidates:
            file_name = candidate
            ts = None
            try:
                ts = os.path.getmtime(file_name)
                break
            except:
                # try another or delay error check to open()
                continue
        # style changed, different file name or file modified in the meanwhile
        if style_changed or file_name != self.file_name or ts and ts > self.ts:
            try:
                # reload the source file if changed
                with io.open(file_name, errors='replace') as source_file:
                    highlighter = Beautifier(file_name, self.tab_size)
                    self.highlighted = highlighter.active
                    source = highlighter.process(source_file.read())
                    self.source_lines = source.split('\n')
                # store file name and timestamp only if success to have
                # persistent errors
                self.file_name = file_name
                self.ts = ts
            except IOError as e:
                msg = 'Cannot display "{}"'.format(file_name)
                return [ansi(msg, R.style_error)]
        # compute the line range
        height = self.height or (term_height - 1)
        start = current_line - 1 - int(height / 2) + self.offset
        end = start + height
        # extra at start
        extra_start = 0
        if start < 0:
            extra_start = min(-start, height)
            start = 0
        # extra at end
        extra_end = 0
        if end > len(self.source_lines):
            extra_end = min(end - len(self.source_lines), height)
            end = len(self.source_lines)
        else:
            end = max(end, 0)
        # return the source code listing
        breakpoints = fetch_breakpoints()
        out = []
        number_format = '{{:>{}}}'.format(len(str(end)))
        for number, line in enumerate(self.source_lines[start:end], start + 1):
            # properly handle UTF-8 source files
            line = to_string(line)
            if int(number) == current_line:
                # the current line has a different style without ANSI
                if R.ansi:
                    if self.highlighted and not self.highlight_line:
                        line_format = '{}' + ansi(number_format, R.style_selected_1) + '  {}'
                    else:
                        line_format = '{}' + ansi(number_format + '  {}', R.style_selected_1)
                else:
                    # just show a plain text indicator
                    line_format = '{}' + number_format + '> {}'
            else:
                line_format = '{}' + ansi(number_format, R.style_low) + '  {}'
            # check for breakpoint presence
            enabled = None
            for breakpoint in breakpoints:
                addresses = breakpoint['addresses']
                is_root_enabled = addresses[0]['enabled']
                for address in addresses:
                    # note, despite the lookup path always use the relative
                    # (sal.symtab.filename) file name to match source files with
                    # breakpoints
                    if address['file_line'] == number and address['file_name'] == sal.symtab.filename:
                        enabled = enabled or (address['enabled'] and is_root_enabled)
            if enabled is None:
                breakpoint = ' '
            else:
                breakpoint = ansi('!', R.style_critical) if enabled else ansi('-', R.style_low)
            out.append(line_format.format(breakpoint, number, line.rstrip('\n')))
        # return the output along with scroll indicators
        if len(out) <= height:
            extra = [ansi('~', R.style_low)]
            return extra_start * extra + out + extra_end * extra
        else:
            return out

    def commands(self):
        return {
            'scroll': {
                'action': self.scroll,
                'doc': 'Scroll by relative steps or reset if invoked without argument.'
            }
        }

    def attributes(self):
        return {
            'height': {
                'doc': '''Height of the module.

A value of 0 uses the whole height.''',
                'default': 10,
                'type': int,
                'check': check_ge_zero
            },
            'tab-size': {
                'doc': 'Number of spaces used to display the tab character.',
                'default': 4,
                'name': 'tab_size',
                'type': int,
                'check': check_gt_zero
            },
            'path': {
                'doc': 'Path visibility flag in the module label.',
                'default': False,
                'name': 'show_path',
                'type': bool
            },
            'highlight-line': {
                'doc': 'Decide whether the whole current line should be highlighted.',
                'default': False,
                'name': 'highlight_line',
                'type': bool
            }
        }

    def scroll(self, arg):
        if arg:
            self.offset += int(arg)
        else:
            self.offset = 0

class Assembly(Dashboard.Module):
    '''Show the disassembled code surrounding the program counter.

The instructions constituting the current statement are marked, if available.'''

    def __init__(self):
        self.offset = 0
        self.cache_key = None
        self.cache_asm = None

    def label(self):
        return 'Assembly'

    def lines(self, term_width, term_height, style_changed):
        # skip if the current thread is not stopped
        if not gdb.selected_thread().is_stopped():
            return []
        # flush the cache if the style is changed
        if style_changed:
            self.cache_key = None
        # prepare the highlighter
        try:
            flavor = gdb.parameter('disassembly-flavor')
        except:
            flavor = 'att'  # not always defined (see #36)
        highlighter = Beautifier(flavor, tab_size=None)
        # fetch the assembly code
        line_info = None
        frame = gdb.selected_frame()  # PC is here
        height = self.height or (term_height - 1)
        try:
            # disassemble the current block
            asm_start, asm_end = self.fetch_function_boundaries()
            asm = self.fetch_asm(asm_start, asm_end, False, highlighter)
            # find the location of the PC
            pc_index = next(index for index, instr in enumerate(asm)
                            if instr['addr'] == frame.pc())
            # compute the instruction range
            start = pc_index - int(height / 2) + self.offset
            end = start + height
            # extra at start
            extra_start = 0
            if start < 0:
                extra_start = min(-start, height)
                start = 0
            # extra at end
            extra_end = 0
            if end > len(asm):
                extra_end = min(end - len(asm), height)
                end = len(asm)
            else:
                end = max(end, 0)
            # fetch actual interval
            asm = asm[start:end]
            # if there are line information then use it, it may be that
            # line_info is not None but line_info.last is None
            line_info = gdb.find_pc_line(frame.pc())
            line_info = line_info if line_info.last else None
        except (gdb.error, RuntimeError, StopIteration):
            # if it is not possible (stripped binary or the PC is not present in
            # the output of `disassemble` as per issue #31) start from PC
            try:
                extra_start = 0
                extra_end = 0
                # allow to scroll down nevertheless
                clamped_offset = min(self.offset, 0)
                asm = self.fetch_asm(frame.pc(), height - clamped_offset, True, highlighter)
                asm = asm[-clamped_offset:]
            except gdb.error as e:
                msg = '{}'.format(e)
                return [ansi(msg, R.style_error)]
        # fetch function start if available (e.g., not with @plt)
        func_start = None
        if self.show_function and frame.function():
            func_start = to_unsigned(frame.function().value())
        # compute the maximum offset size
        if asm and func_start:
            max_offset = max(len(str(abs(asm[0]['addr'] - func_start))),
                             len(str(abs(asm[-1]['addr'] - func_start))))
        # return the machine code
        breakpoints = fetch_breakpoints()
        max_length = max(instr['length'] for instr in asm) if asm else 0
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
                opcodes = (' '.join('{:02x}'.format(ord(byte)) for byte in region))
                opcodes += (max_length - len(region)) * 3 * ' ' + '  '
            else:
                opcodes = ''
            # compute the offset if available
            if self.show_function:
                if func_start:
                    offset = '{:+d}'.format(addr - func_start)
                    offset = offset.ljust(max_offset + 1)  # sign
                    func_info = '{}{}'.format(frame.function(), offset)
                else:
                    func_info = '?'
            else:
                func_info = ''
            format_string = '{}{}{}{}{}{}'
            indicator = '  '
            text = ' ' + text
            if addr == frame.pc():
                if not R.ansi:
                    indicator = '> '
                addr_str = ansi(addr_str, R.style_selected_1)
                indicator = ansi(indicator, R.style_selected_1)
                opcodes = ansi(opcodes, R.style_selected_1)
                func_info = ansi(func_info, R.style_selected_1)
                if not highlighter.active or self.highlight_line:
                    text = ansi(text, R.style_selected_1)
            elif line_info and line_info.pc <= addr < line_info.last:
                if not R.ansi:
                    indicator = ': '
                addr_str = ansi(addr_str, R.style_selected_2)
                indicator = ansi(indicator, R.style_selected_2)
                opcodes = ansi(opcodes, R.style_selected_2)
                func_info = ansi(func_info, R.style_selected_2)
                if not highlighter.active or self.highlight_line:
                    text = ansi(text, R.style_selected_2)
            else:
                addr_str = ansi(addr_str, R.style_low)
                func_info = ansi(func_info, R.style_low)
            # check for breakpoint presence
            enabled = None
            for breakpoint in breakpoints:
                addresses = breakpoint['addresses']
                is_root_enabled = addresses[0]['enabled']
                for address in addresses:
                    if address['address'] == addr:
                        enabled = enabled or (address['enabled'] and is_root_enabled)
            if enabled is None:
                breakpoint = ' '
            else:
                breakpoint = ansi('!', R.style_critical) if enabled else ansi('-', R.style_low)
            out.append(format_string.format(breakpoint, addr_str, indicator, opcodes, func_info, text))
        # return the output along with scroll indicators
        if len(out) <= height:
            extra = [ansi('~', R.style_low)]
            return extra_start * extra + out + extra_end * extra
        else:
            return out

    def commands(self):
        return {
            'scroll': {
                'action': self.scroll,
                'doc': 'Scroll by relative steps or reset if invoked without argument.'
            }
        }

    def attributes(self):
        return {
            'height': {
                'doc': '''Height of the module.

A value of 0 uses the whole height.''',
                'default': 10,
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
            },
            'highlight-line': {
                'doc': 'Decide whether the whole current line should be highlighted.',
                'default': False,
                'name': 'highlight_line',
                'type': bool
            }
        }

    def scroll(self, arg):
        if arg:
            self.offset += int(arg)
        else:
            self.offset = 0

    def fetch_function_boundaries(self):
        frame = gdb.selected_frame()
        # parse the output of the disassemble GDB command to find the function
        # boundaries, this should handle cases in which a function spans
        # multiple discontinuous blocks
        disassemble = run('disassemble')
        for block_start, block_end in re.findall(r'Address range 0x([0-9a-f]+) to 0x([0-9a-f]+):', disassemble):
            block_start = int(block_start, 16)
            block_end = int(block_end, 16)
            if block_start <= frame.pc() < block_end:
                return block_start, block_end - 1 # need to be inclusive
        # if function information is available then try to obtain the
        # boundaries by looking at the superblocks
        block = frame.block()
        if frame.function():
            while block and (not block.function or block.function.name != frame.function().name):
                block = block.superblock
            block = block or frame.block()
        return block.start, block.end - 1

    def fetch_asm(self, start, end_or_count, relative, highlighter):
        # fetch asm from cache or disassemble
        if self.cache_key == (start, end_or_count):
            asm = self.cache_asm
        else:
            kwargs = {
                'start_pc': start,
                'count' if relative else 'end_pc': end_or_count
            }
            asm = gdb.selected_frame().architecture().disassemble(**kwargs)
            self.cache_key = (start, end_or_count)
            self.cache_asm = asm
            # syntax highlight the cached entry
            for instr in asm:
                instr['asm'] = highlighter.process(instr['asm'])
        return asm

class Variables(Dashboard.Module):
    '''Show arguments and locals of the selected frame.'''

    def label(self):
        return 'Variables'

    def lines(self, term_width, term_height, style_changed):
        return Variables.format_frame(
            gdb.selected_frame(), self.show_arguments, self.show_locals, self.compact, self.align, self.sort)

    def attributes(self):
        return {
            'arguments': {
                'doc': 'Frame arguments visibility flag.',
                'default': True,
                'name': 'show_arguments',
                'type': bool
            },
            'locals': {
                'doc': 'Frame locals visibility flag.',
                'default': True,
                'name': 'show_locals',
                'type': bool
            },
            'compact': {
                'doc': 'Single-line display flag.',
                'default': True,
                'type': bool
            },
            'align': {
                'doc': 'Align variables in column flag (only if not compact).',
                'default': False,
                'type': bool
            },
            'sort': {
                'doc': 'Sort variables by name.',
                'default': False,
                'type': bool
            }
        }

    @staticmethod
    def format_frame(frame, show_arguments, show_locals, compact, align, sort):
        out = []
        # fetch frame arguments and locals
        decorator = gdb.FrameDecorator.FrameDecorator(frame)
        separator = ansi(', ', R.style_low)
        if show_arguments:
            def prefix(line):
                return Stack.format_line('arg', line)
            frame_args = decorator.frame_args()
            args_lines = Variables.fetch(frame, frame_args, compact, align, sort)
            if args_lines:
                if compact:
                    args_line = separator.join(args_lines)
                    single_line = prefix(args_line)
                    out.append(single_line)
                else:
                    out.extend(map(prefix, args_lines))
        if show_locals:
            def prefix(line):
                return Stack.format_line('loc', line)
            frame_locals = decorator.frame_locals()
            locals_lines = Variables.fetch(frame, frame_locals, compact, align, sort)
            if locals_lines:
                if compact:
                    locals_line = separator.join(locals_lines)
                    single_line = prefix(locals_line)
                    out.append(single_line)
                else:
                    out.extend(map(prefix, locals_lines))
        return out

    @staticmethod
    def fetch(frame, data, compact, align, sort):
        lines = []
        name_width = 0
        if align and not compact:
            name_width = max(len(str(elem.sym)) for elem in data) if data else 0
        for elem in data or []:
            name = ansi(elem.sym, R.style_high) + ' ' * (name_width - len(str(elem.sym)))
            equal = ansi('=', R.style_low)
            value = format_value(elem.sym.value(frame), compact)
            lines.append('{} {} {}'.format(name, equal, value))
        if sort:
            lines.sort()
        return lines

class Stack(Dashboard.Module):
    '''Show the current stack trace including the function name and the file location, if available.

Optionally list the frame arguments and locals too.'''

    def label(self):
        return 'Stack'

    def lines(self, term_width, term_height, style_changed):
        # skip if the current thread is not stopped
        if not gdb.selected_thread().is_stopped():
            return []
        # find the selected frame (i.e., the first to display)
        selected_index = 0
        frame = gdb.newest_frame()
        while frame:
            if frame == gdb.selected_frame():
                break
            frame = frame.older()
            selected_index += 1
        # format up to "limit" frames
        frames = []
        number = selected_index
        more = False
        while frame:
            # the first is the selected one
            selected = (len(frames) == 0)
            # fetch frame info
            style = R.style_selected_1 if selected else R.style_selected_2
            frame_id = ansi(str(number), style)
            info = Stack.get_pc_line(frame, style)
            frame_lines = []
            frame_lines.append('[{}] {}'.format(frame_id, info))
            # add frame arguments and locals
            variables = Variables.format_frame(
                frame, self.show_arguments, self.show_locals, self.compact, self.align, self.sort)
            frame_lines.extend(variables)
            # add frame
            frames.append(frame_lines)
            # next
            frame = frame.older()
            number += 1
            # check finished according to the limit
            if self.limit and len(frames) == self.limit:
                # more frames to show but limited
                if frame:
                    more = True
                break
        # format the output
        lines = []
        for frame_lines in frames:
            lines.extend(frame_lines)
        # add the placeholder
        if more:
            lines.append('[{}]'.format(ansi('+', R.style_selected_2)))
        return lines

    def attributes(self):
        return {
            'limit': {
                'doc': 'Maximum number of displayed frames (0 means no limit).',
                'default': 10,
                'type': int,
                'check': check_ge_zero
            },
            'arguments': {
                'doc': 'Frame arguments visibility flag.',
                'default': False,
                'name': 'show_arguments',
                'type': bool
            },
            'locals': {
                'doc': 'Frame locals visibility flag.',
                'default': False,
                'name': 'show_locals',
                'type': bool
            },
            'compact': {
                'doc': 'Single-line display flag.',
                'default': False,
                'type': bool
            },
            'align': {
                'doc': 'Align variables in column flag (only if not compact).',
                'default': False,
                'type': bool
            },
            'sort': {
                'doc': 'Sort variables by name.',
                'default': False,
                'type': bool
            }
        }

    @staticmethod
    def format_line(prefix, line):
        prefix = ansi(prefix, R.style_low)
        return '{} {}'.format(prefix, line)

    @staticmethod
    def get_pc_line(frame, style):
        frame_pc = ansi(format_address(frame.pc()), style)
        info = 'from {}'.format(frame_pc)
        # if a frame function symbol is available then use it to fetch the
        # current function name and address, otherwise fall back relying on the
        # frame name
        if frame.function():
            name = ansi(frame.function(), style)
            func_start = to_unsigned(frame.function().value())
            offset = ansi(str(frame.pc() - func_start), style)
            info += ' in {}+{}'.format(name, offset)
        elif frame.name():
            name = ansi(frame.name(), style)
            info += ' in {}'.format(name)
        sal = frame.find_sal()
        if sal and sal.symtab:
            file_name = ansi(sal.symtab.filename, style)
            file_line = ansi(str(sal.line), style)
            info += ' at {}:{}'.format(file_name, file_line)
        return info

class History(Dashboard.Module):
    '''List the last entries of the value history.'''

    def label(self):
        return 'History'

    def lines(self, term_width, term_height, style_changed):
        out = []
        # fetch last entries
        for i in range(-self.limit + 1, 1):
            try:
                value = format_value(gdb.history(i))
                value_id = ansi('$${}', R.style_high).format(abs(i))
                equal = ansi('=', R.style_low)
                line = '{} {} {}'.format(value_id, equal, value)
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
    '''Allow to inspect memory regions.'''

    DEFAULT_LENGTH = 16

    class Region():
        def __init__(self, expression, length, module):
            self.expression = expression
            self.length = length
            self.module = module
            self.original = None
            self.latest = None

        def reset(self):
            self.original = None
            self.latest = None

        def format(self, per_line):
            # fetch the memory content
            try:
                address = Memory.parse_as_address(self.expression)
                inferior = gdb.selected_inferior()
                memory = inferior.read_memory(address, self.length)
                # set the original memory snapshot if needed
                if not self.original:
                    self.original = memory
            except gdb.error as e:
                msg = 'Cannot access {} bytes starting at {}: {}'
                msg = msg.format(self.length, self.expression, e)
                return [ansi(msg, R.style_error)]
            # format the memory content
            out = []
            for i in range(0, len(memory), per_line):
                region = memory[i:i + per_line]
                pad = per_line - len(region)
                address_str = format_address(address + i)
                # compute changes
                hexa = []
                text = []
                for j in range(len(region)):
                    rel = i + j
                    byte = memory[rel]
                    hexa_byte = '{:02x}'.format(ord(byte))
                    text_byte = self.module.format_byte(byte)
                    # differences against the latest have the highest priority
                    if self.latest and memory[rel] != self.latest[rel]:
                        hexa_byte = ansi(hexa_byte, R.style_selected_1)
                        text_byte = ansi(text_byte, R.style_selected_1)
                    # cumulative changes if enabled
                    elif self.module.cumulative and memory[rel] != self.original[rel]:
                        hexa_byte = ansi(hexa_byte, R.style_selected_2)
                        text_byte = ansi(text_byte, R.style_selected_2)
                    # format the text differently for clarity
                    else:
                        text_byte = ansi(text_byte, R.style_high)
                    hexa.append(hexa_byte)
                    text.append(text_byte)
                # output the formatted line
                hexa_placeholder = ' {}'.format(self.module.placeholder[0] * 2)
                text_placeholder = self.module.placeholder[0]
                out.append('{}  {}{}  {}{}'.format(
                    ansi(address_str, R.style_low),
                    ' '.join(hexa), ansi(pad * hexa_placeholder, R.style_low),
                    ''.join(text), ansi(pad * text_placeholder, R.style_low)))
            # update the latest memory snapshot
            self.latest = memory
            return out

    def __init__(self):
        self.table = {}

    def label(self):
        return 'Memory'

    def lines(self, term_width, term_height, style_changed):
        out = []
        for expression, region in self.table.items():
            out.append(divider(term_width, expression))
            out.extend(region.format(self.get_per_line(term_width)))
        return out

    def commands(self):
        return {
            'watch': {
                'action': self.watch,
                'doc': '''Watch a memory region by expression and length.

The length defaults to 16 bytes.''',
                'complete': gdb.COMPLETE_EXPRESSION
            },
            'unwatch': {
                'action': self.unwatch,
                'doc': 'Stop watching a memory region by expression.',
                'complete': gdb.COMPLETE_EXPRESSION
            },
            'clear': {
                'action': self.clear,
                'doc': 'Clear all the watched regions.'
            }
        }

    def attributes(self):
        return {
            'cumulative': {
                'doc': 'Highlight changes cumulatively, watch again to reset.',
                'default': False,
                'type': bool
            },
            'full': {
                'doc': 'Take the whole horizontal space.',
                'default': False,
                'type': bool
            },
            'placeholder': {
                'doc': 'Placeholder used for missing items and unprintable characters.',
                'default': '·'
            }
        }

    def watch(self, arg):
        if arg:
            expression, _, length_str = arg.partition(' ')
            length = Memory.parse_as_address(length_str) if length_str else Memory.DEFAULT_LENGTH
            # keep the length when the memory is watched to reset the changes
            region = self.table.get(expression)
            if region and not length_str:
                region.reset()
            else:
                self.table[expression] = Memory.Region(expression, length, self)
        else:
            raise Exception('Specify a memory location')

    def unwatch(self, arg):
        if arg:
            try:
                del self.table[arg]
            except KeyError:
                raise Exception('Memory expression not watched')
        else:
            raise Exception('Specify a matched memory expression')

    def clear(self, arg):
        self.table.clear()

    def format_byte(self, byte):
        # `type(byte) is bytes` in Python 3
        if 0x20 < ord(byte) < 0x7f:
            return chr(ord(byte))
        else:
            return self.placeholder[0]

    def get_per_line(self, term_width):
        if self.full:
            padding = 3  # two double spaces separator (one is part of below)
            elem_size = 4 # HH + 1 space + T
            address_length = gdb.parse_and_eval('$pc').type.sizeof * 2 + 2  # 0x
            return max(int((term_width - address_length - padding) / elem_size), 1)
        else:
            return Memory.DEFAULT_LENGTH

    @staticmethod
    def parse_as_address(expression):
        value = gdb.parse_and_eval(expression)
        return to_unsigned(value)

class Registers(Dashboard.Module):
    '''Show the CPU registers and their values.'''

    def __init__(self):
        self.table = {}

    def label(self):
        return 'Registers'

    def lines(self, term_width, term_height, style_changed):
        # skip if the current thread is not stopped
        if not gdb.selected_thread().is_stopped():
            return []
        # obtain the registers to display
        if style_changed:
            self.table = {}
        if self.register_list:
            register_list = self.register_list.split()
        else:
            register_list = Registers.fetch_register_list()
        # fetch registers status
        registers = []
        for name in register_list:
            # exclude registers with a dot '.' or parse_and_eval() will fail
            if '.' in name:
                continue
            value = gdb.parse_and_eval('${}'.format(name))
            string_value = Registers.format_value(value)
            # exclude unavailable registers (see #255)
            if string_value == '<unavailable>':
                continue
            changed = self.table and (self.table.get(name, '') != string_value)
            self.table[name] = string_value
            registers.append((name, string_value, changed))
        # compute lengths considering an extra space between and around the
        # entries (hence the +2 and term_width - 1)
        max_name = max(len(name) for name, _, _ in registers)
        max_value = max(len(value) for _, value, _ in registers)
        max_width = max_name + max_value + 2
        columns = min(int((term_width - 1) / max_width) or 1, len(registers))
        rows = int(math.ceil(float(len(registers)) / columns))
        # build the registers matrix
        if self.column_major:
            matrix = list(registers[i:i + rows] for i in range(0, len(registers), rows))
        else:
            matrix = list(registers[i::columns] for i in range(columns))
        # compute the lengths column wise
        max_names_column = list(max(len(name) for name, _, _ in column) for column in matrix)
        max_values_column = list(max(len(value) for _, value, _ in column) for column in matrix)
        line_length = sum(max_names_column) + columns + sum(max_values_column)
        extra = term_width - line_length
        # compute padding as if there were one more column
        base_padding = int(extra / (columns + 1))
        padding_column = [base_padding] * columns
        # distribute the remainder among columns giving the precedence to
        # internal padding
        rest = extra % (columns + 1)
        while rest:
            padding_column[rest % columns] += 1
            rest -= 1
        # format the registers
        out = [''] * rows
        for i, column in enumerate(matrix):
            max_name = max_names_column[i]
            max_value = max_values_column[i]
            for j, (name, value, changed) in enumerate(column):
                name = ' ' * (max_name - len(name)) + ansi(name, R.style_low)
                style = R.style_selected_1 if changed else ''
                value = ansi(value, style) + ' ' * (max_value - len(value))
                padding = ' ' * padding_column[i]
                item = '{}{} {}'.format(padding, name, value)
                out[j] += item
        return out

    def attributes(self):
        return {
            'column-major': {
                'doc': 'Show registers in columns instead of rows.',
                'default': False,
                'name': 'column_major',
                'type': bool
            },
            'list': {
                'doc': '''String of space-separated register names to display.

The empty list (default) causes to show all the available registers.''',
                'default': '',
                'name': 'register_list',
            }
        }

    @staticmethod
    def format_value(value):
        try:
            if value.type.code in [gdb.TYPE_CODE_INT, gdb.TYPE_CODE_PTR]:
                int_value = to_unsigned(value, value.type.sizeof)
                value_format = '0x{{:0{}x}}'.format(2 * value.type.sizeof)
                return value_format.format(int_value)
        except (gdb.error, ValueError):
            # convert to unsigned but preserve code and flags information
            pass
        return str(value)

    @staticmethod
    def fetch_register_list(*match_groups):
        names = []
        for line in run('maintenance print register-groups').split('\n'):
            fields = line.split()
            if len(fields) != 7:
                continue
            name, _, _, _, _, _, groups = fields
            if not re.match('\w', name):
                continue
            for group in groups.split(','):
                if group in (match_groups or ('general',)):
                    names.append(name)
                    break
        return names

class Threads(Dashboard.Module):
    '''List the currently available threads.'''

    def label(self):
        return 'Threads'

    def lines(self, term_width, term_height, style_changed):
        out = []
        selected_thread = gdb.selected_thread()
        # do not restore the selected frame if the thread is not stopped
        restore_frame = gdb.selected_thread().is_stopped()
        if restore_frame:
            selected_frame = gdb.selected_frame()
        # fetch the thread list
        threads = []
        for inferior in gdb.inferiors():
            if self.all_inferiors or inferior == gdb.selected_inferior():
                threads += gdb.Inferior.threads(inferior)
        for thread in threads:
            # skip running threads if requested
            if self.skip_running and thread.is_running():
                continue
            is_selected = (thread.ptid == selected_thread.ptid)
            style = R.style_selected_1 if is_selected else R.style_selected_2
            if self.all_inferiors:
                number = '{}.{}'.format(thread.inferior.num, thread.num)
            else:
                number = str(thread.num)
            number = ansi(number, style)
            tid = ansi(str(thread.ptid[1] or thread.ptid[2]), style)
            info = '[{}] id {}'.format(number, tid)
            if thread.name:
                info += ' name {}'.format(ansi(thread.name, style))
            # switch thread to fetch info (unless is running in non-stop mode)
            try:
                thread.switch()
                frame = gdb.newest_frame()
                info += ' ' + Stack.get_pc_line(frame, style)
            except gdb.error:
                info += ' (running)'
            out.append(info)
        # restore thread and frame
        selected_thread.switch()
        if restore_frame:
            selected_frame.select()
        return out

    def attributes(self):
        return {
            'skip-running': {
                'doc': 'Skip running threads.',
                'default': False,
                'name': 'skip_running',
                'type': bool
            },
            'all-inferiors': {
                'doc': 'Show threads from all inferiors.',
                'default': False,
                'name': 'all_inferiors',
                'type': bool
            },
        }

class Expressions(Dashboard.Module):
    '''Watch user expressions.'''

    def __init__(self):
        self.table = set()

    def label(self):
        return 'Expressions'

    def lines(self, term_width, term_height, style_changed):
        out = []
        label_width = 0
        if self.align:
            label_width = max(len(expression) for expression in self.table) if self.table else 0
        default_radix = Expressions.get_default_radix()
        for expression in self.table:
            label = expression
            match = re.match('^/(\d+) +(.+)$', expression)
            try:
                if match:
                    radix, expression = match.groups()
                    run('set output-radix {}'.format(radix))
                value = format_value(gdb.parse_and_eval(expression))
            except gdb.error as e:
                value = ansi(e, R.style_error)
            finally:
                if match:
                    run('set output-radix {}'.format(default_radix))
            label = ansi(expression, R.style_high) + ' ' * (label_width - len(expression))
            equal = ansi('=', R.style_low)
            out.append('{} {} {}'.format(label, equal, value))
        return out

    def commands(self):
        return {
            'watch': {
                'action': self.watch,
                'doc': 'Watch an expression using the format `[/<radix>] <expression>`.',
                'complete': gdb.COMPLETE_EXPRESSION
            },
            'unwatch': {
                'action': self.unwatch,
                'doc': 'Stop watching an expression.',
                'complete': gdb.COMPLETE_EXPRESSION
            },
            'clear': {
                'action': self.clear,
                'doc': 'Clear all the watched expressions.'
            }
        }

    def attributes(self):
        return {
            'align': {
                'doc': 'Align variables in column flag.',
                'default': False,
                'type': bool
            }
        }

    def watch(self, arg):
        if arg:
            self.table.add(arg)
        else:
            raise Exception('Specify an expression')

    def unwatch(self, arg):
        if arg:
            try:
                self.table.remove(arg)
            except:
                raise Exception('Expression not watched')
        else:
            raise Exception('Specify an expression')

    def clear(self, arg):
        self.table.clear()

    @staticmethod
    def get_default_radix():
        try:
            return gdb.parameter('output-radix')
        except RuntimeError:
            # XXX this is a fix for GDB <8.1.x see #161
            message = run('show output-radix')
            match = re.match('^Default output radix for printing of values is (\d+)\.$', message)
            return match.groups()[0] if match else 10  # fallback

# XXX workaround to support BP_BREAKPOINT in older GDB versions
setattr(gdb, 'BP_CATCHPOINT', getattr(gdb, 'BP_CATCHPOINT', 26))

class Breakpoints(Dashboard.Module):
    '''Display the breakpoints list.'''

    NAMES = {
        gdb.BP_BREAKPOINT: 'break',
        gdb.BP_WATCHPOINT: 'watch',
        gdb.BP_HARDWARE_WATCHPOINT: 'write watch',
        gdb.BP_READ_WATCHPOINT: 'read watch',
        gdb.BP_ACCESS_WATCHPOINT: 'access watch',
        gdb.BP_CATCHPOINT: 'catch'
    }

    def label(self):
        return 'Breakpoints'

    def lines(self, term_width, term_height, style_changed):
        out = []
        breakpoints = fetch_breakpoints(watchpoints=True, pending=self.show_pending)
        for breakpoint in breakpoints:
            sub_lines = []
            # format common information
            style = R.style_selected_1 if breakpoint['enabled'] else R.style_selected_2
            number = ansi(breakpoint['number'], style)
            bp_type = ansi(Breakpoints.NAMES[breakpoint['type']], style)
            if breakpoint['temporary']:
                bp_type = bp_type + ' {}'.format(ansi('once', style))
            if not R.ansi and breakpoint['enabled']:
                bp_type = 'disabled ' + bp_type
            line = '[{}] {}'.format(number, bp_type)
            if breakpoint['type'] == gdb.BP_BREAKPOINT:
                for i, address in enumerate(breakpoint['addresses']):
                    addr = address['address']
                    if i == 0 and addr:
                        # this is a regular breakpoint
                        line += ' at {}'.format(ansi(format_address(addr), style))
                        # format source information
                        file_name = address.get('file_name')
                        file_line = address.get('file_line')
                        if file_name and file_line:
                            file_name = ansi(file_name, style)
                            file_line = ansi(file_line, style)
                            line += ' in {}:{}'.format(file_name, file_line)
                    elif i > 0:
                        # this is a sub breakpoint
                        sub_style = R.style_selected_1 if address['enabled'] else R.style_selected_2
                        sub_number = ansi('{}.{}'.format(breakpoint['number'], i), sub_style)
                        sub_line = '[{}]'.format(sub_number)
                        sub_line += ' at {}'.format(ansi(format_address(addr), sub_style))
                        # format source information
                        file_name = address.get('file_name')
                        file_line = address.get('file_line')
                        if file_name and file_line:
                            file_name = ansi(file_name, sub_style)
                            file_line = ansi(file_line, sub_style)
                            sub_line += ' in {}:{}'.format(file_name, file_line)
                        sub_lines += [sub_line]
                # format user location
                location = breakpoint['location']
                line += ' for {}'.format(ansi(location, style))
            elif breakpoint['type'] == gdb.BP_CATCHPOINT:
                what = breakpoint['what']
                line += ' {}'.format(ansi(what, style))
            else:
                # format user expression
                expression = breakpoint['expression']
                line += ' for {}'.format(ansi(expression, style))
            # format condition
            condition = breakpoint['condition']
            if condition:
                line += ' if {}'.format(ansi(condition, style))
            # format hit count
            hit_count = breakpoint['hit_count']
            if hit_count:
                word = 'time{}'.format('s' if hit_count > 1 else '')
                line += ' hit {} {}'.format(ansi(breakpoint['hit_count'], style), word)
            # append the main line and possibly sub breakpoints
            out.append(line)
            out.extend(sub_lines)
        return out

    def attributes(self):
        return {
            'pending': {
                'doc': 'Also show pending breakpoints.',
                'default': True,
                'name': 'show_pending',
                'type': bool
            }
        }

# XXX traceback line numbers in this Python block must be increased by 1
end

# Better GDB defaults ----------------------------------------------------------

set history save
set verbose off
set print pretty on
set print array off
set print array-indexes on
set python print-stack full

# Start ------------------------------------------------------------------------

python Dashboard.start()

# File variables ---------------------------------------------------------------

# vim: filetype=python
# Local Variables:
# mode: python
# End:
