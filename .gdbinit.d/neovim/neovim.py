
# Common decorators ------------------------------------------------------------

class memorize(dict):
    def __init__(self, func):
        self.func = func

    def __call__(self, *args):
        return self[args]

    def __missing__(self, key):
        result = self[key] = self.func(*key)
        return result

# Common methods --------------------------------------------------------------

@memorize
def nvim():
    # check if we run from withing of nvim if true we want to debug using nvim
    try:
        import neovim
    except ImportError:
        # silently ignore, probably user does not want this feature
        return None
    address = os.getenv('NVIM_LISTEN_ADDRESS')
    if address is not None:
        return neovim.attach('socket', path=address)
    return None

# Module definition ------------------------------------------------------------

if nvim():
    class Nvim(Dashboard.Module):
        """Show the program source code, if available."""

        def __init__(self):
            # suppress Source module
            try:
                del globals()['Source']
            except NameError:
                pass


            self.file_name = None
            self.source_lines = []
            self.ts = None
            self.highlighted = False

            # remember the gdb_buffer
            self.gdb_window = nvim().current.window
            self.gdb_buffer = nvim().current.buffer
            # create a split for code
            nvim().command('split')
            self.code_window = nvim().current.window
            # get focus back on gdb
            nvim().current.window = self.gdb_window
            # define signs
            nvim().command('sign define GdbCurrentLine text=⇒')
            nvim().command('sign define GdbBreakpoint text=●')

        def label(self):
            return 'Nvim'

        def lines(self, style_changed):
            # use shorter form
            nvim().command('sign unplace 5000')
            # try to fetch the current line (skip if no line information)
            sal = gdb.selected_frame().find_sal()
            current_line = sal.line
            if current_line == 0:
                return None
            # reload the source file if changed
            file_name = sal.symtab.fullname()
            ts = None
            try:
                ts = os.path.getmtime(file_name)
            except:
                pass  # delay error check to open()
            if (style_changed or
                    file_name != self.file_name or  # different file name
                    ts and ts > self.ts):  # file modified in the meanwhile
                self.file_name = file_name
                self.ts = ts
                try:
                    with open(self.file_name) as source_file:
                        self.highlighted, source = highlight(source_file.read(),
                                                             self.file_name)
                        self.source_lines = source.split('\n')
                except Exception as e:
                    msg = 'Cannot display "{}" ({})'.format(self.file_name, e)
                    return [ansi(msg, R.style_error)]
            current_window = nvim().current.window
            nvim().current.window = self.code_window
            nvim().command('edit! +' + str(current_line) + ' ' + self.file_name )
            nvim().current.window = current_window
            nvim().command('sign place 5000 name=GdbCurrentLine line=' + str(current_line) + ' file=' + self.file_name )
            return None

        def attributes(self):
            return {
            }
