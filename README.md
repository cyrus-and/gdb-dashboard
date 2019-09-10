# GDB dashboard

GDB dashboard is a standalone `.gdbinit` file written using the [Python API][] that enables a modular interface showing relevant information about the program being debugged. Its main goal is to reduce the number of GDB commands needed to inspect the status of current program thus allowing the developer to primarily focus on the control flow.

![Screenshot](https://raw.githubusercontent.com/wiki/cyrus-and/gdb-dashboard/Screenshot.png)

[Python API]: https://sourceware.org/gdb/onlinedocs/gdb/Python-API.html

## Quickstart

Just place [`.gdbinit`][] in your home directory, for example with:

```
wget -P ~ https://git.io/.gdbinit
```

Optionally install [Pygments][] to enable syntax highlighting:

```
pip install pygments
```

Then debug as usual, the dashboard will appear automatically when the inferior program stops.

Keep in mind that no GDB command has been redefined, instead all the features are available via the main `dashboard` command (see `help dashboard`).

The [wiki][] also can be useful as it contains some common use cases.

[`.gdbinit`]: https://raw.githubusercontent.com/cyrus-and/gdb-dashboard/master/.gdbinit
[Pygments]: http://pygments.org/
[wiki]: https://github.com/cyrus-and/gdb-dashboard/wiki

## Configuration

Files in `~/.gdbinit.d/` are executed in alphabetical order, but the preference is given to Python files. If there are subdirectories, they are walked recursively. The idea is to keep separated the custom modules definition from the configuration itself.

By convention, the *main* configuration file should be placed in `~/.gdbinit.d/` (say `~/.gdbinit.d/init`) and can be used to tune the dashboard styles and modules configuration but also the usual GDB parameters.
