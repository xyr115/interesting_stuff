# This file is created by Homebrew and is executed on each python startup.
# Don't print from here, or else python command line scripts may fail!
# <https://docs.brew.sh/Homebrew-and-Python>
import re
import os
import sys

if sys.version_info[0] != 2:
    # This can only happen if the user has set the PYTHONPATH for 3.x and run Python 2.x or vice versa.
    # Every Python looks at the PYTHONPATH variable and we can't fix it here in sitecustomize.py,
    # because the PYTHONPATH is evaluated after the sitecustomize.py. Many modules (e.g. PyQt4) are
    # built only for a specific version of Python and will fail with cryptic error messages.
    # In the end this means: Don't set the PYTHONPATH permanently if you use different Python versions.
    exit('Your PYTHONPATH points to a site-packages dir for Python 2.x but you are running Python ' +
         str(sys.version_info[0]) + '.x!\n     PYTHONPATH is currently: "' + str(os.environ['PYTHONPATH']) + '"\n' +
         '     You should `unset PYTHONPATH` to fix this.')

# Only do this for a brewed python:
if os.path.realpath(sys.executable).startswith('/usr/local/Cellar/python@2'):
    # Shuffle /Library site-packages to the end of sys.path and reject
    # paths in /System pre-emptively (#14712)
    library_site = '/Library/Python/2.7/site-packages'
    library_packages = [p for p in sys.path if p.startswith(library_site)]
    sys.path = [p for p in sys.path if not p.startswith(library_site) and
                                       not p.startswith('/System')]
    # .pth files have already been processed so don't use addsitedir
    sys.path.extend(library_packages)

    # the Cellar site-packages is a symlink to the HOMEBREW_PREFIX
    # site_packages; prefer the shorter paths
    long_prefix = re.compile(r'/usr/local/Cellar/python@2/[0-9._abrc]+/Frameworks/Python.framework/Versions/2.7/lib/python2.7/site-packages')
    sys.path = [long_prefix.sub('/usr/local/lib/python2.7/site-packages', p) for p in sys.path]

    # LINKFORSHARED (and python-config --ldflags) return the
    # full path to the lib (yes, "Python" is actually the lib, not a
    # dir) so that third-party software does not need to add the
    # -F//usr/local/Frameworks switch.
    try:
        from _sysconfigdata import build_time_vars
        build_time_vars['LINKFORSHARED'] = '-u _PyMac_Error /usr/local/opt/python@2/Frameworks/Python.framework/Versions/2.7/Python'
    except:
        pass  # remember: don't print here. Better to fail silently.

    # Set the sys.executable to use the opt_prefix
    sys.executable = '/usr/local/opt/python@2/bin/python2.7'
