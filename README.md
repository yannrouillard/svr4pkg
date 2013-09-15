svr4pkg
=======

Basic perl implementation of solaris native svr4 packages tools.

Description
-----------

Svr4pkg is a tool that emulates the basic behaviour of the set of solaris
tools used to manipulate svr4 packages (pkgadd, pkgrm, pkginfo...).

It aimed at being used on illumos-based operating systems that do not provide
the svr4 package tools. svr4pkg will allow to easily nstall on these systems
legacy svr4 packages or even a whole existing svr4 packages stack (like
http://www.opencsw.org).

Warnings
--------

Svr4pkg must not be used on a system where pkgadd, pkgrm are available.
svr4pkg is not guaranteed to be fully compatible with solaris native tools
so you could mess badly with the package database if you use both tools on
the same system.

Limitations
-----------

svr4pkg doesn't aim at being fully compatible with native tools and implement
all of its features. It only implement the required basic features allowing to
install most standard packages.

That being said, feel free to open a bug if you encounter an issue with a package:
https://github.com/yannrouillard/svr4pkg/issues

Installation and usage
----------------------

To install svr4pkg, just download the svr4pkg script and install it anywhere in
your path. You can then use it to:

* install a package:

        svr4pkg add -d /path/to/package.pkg

* remove a package:

        svr4pkg rm svr4_package_name

* get the list of installed packages:

        svr4pkg info


You can also create symlink from native svr4 packages tools to svr4pkg, svr4pkg
will behave like the original tools when it detects it is called with the same name.
For example:

        ln -s svr4pkg pkgadd
        pkgadd -d /path/to/package.pkg


Installation for opencsw
------------------------

svr4pkg nicely plays with the opencsw distribution available at http://www.opencsw.org.
You can use svr4pkg to install the whole opencsw stack on smartos for instance. 
Just the follow the steps below:

*   To bootstrap the installation, first install the svr4pkg
    script alone using the following commands:

        mkdir -p /opt/csw/bin
        curl -L -o /opt/csw/bin/svr4pkg http://goo.gl/WaidPy
        chmod +x /opt/csw/bin/svr4pkg

*   Then use the script itself to install the real svr4pkg package.
    This one will create symlinks to the native tools name (pkgadd,
    pkgrm, pkginfo...) that are required to be used as a drop-in 
    replacement and to work with pkgutil.
   
        /opt/csw/bin/svr4pkg add -n -d http://goo.gl/8zURSM

*   You can then the follow the standard opencsw manual to install
    the opencsw distribution:
    http://www.opencsw.org/manual/for-administrators/getting-started.html

    The svr4pkg package is part of the opencsw distribution so it will
    be easily updated with pkgutil.

