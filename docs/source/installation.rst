Installation
============

Static binary
-------------

A statically compiled binary, built automatically with Nix from the up-to-date development version, can be downloaded `here <https://gwaithimirdain.github.io/narya/releases/narya-master-static.tar.gz>`_.  This ought to work on any Linux computer, including on Windows using WSL (see :ref:`On Windows`).

The executable
^^^^^^^^^^^^^^

After downloading and unpacking the `static distribution <https://gwaithimirdain.github.io/narya/releases/narya-master-static.tar.gz>`_, place the ``narya`` executable in a directory that's in your ``PATH``.  On some flavors of Linux, the directory ``~/bin`` is automatically in your path if it exists, so the first thing to try is

.. code-block:: bash

  mkdir -p ~/bin
  cp narya ~/bin

Then restart your shell (i.e. terminal or command prompt) and try running ``narya``.  If that doesn't work, try logging out and back in again.  If that still doesn't work, try something like the following:

.. code-block:: bash

  echo export PATH="\$HOME/bin:\$PATH" >>~/.bashrc

and then once again restart your shell, or log out and back in again.

.. _Static distribution ProofGeneral mode:

ProofGeneral mode (automatic installation)
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

The static binary distribution also includes the recommended Narya :ref:`ProofGeneral mode` and a shell script that should install it, along with ProofGeneral, on any Linux machine (including WSL).  You'll need to install `Emacs <https://www.gnu.org/software/emacs/>`_ yourself first.  On many modern distributions you can install Emacs with

.. code-block:: bash

  sudo snap install emacs

Then run the supplied shell script ``install-pg.sh`` from the static distribution:

.. code-block:: bash

  ./install-pg.sh

If that doesn't work, please report a bug on `GitHub <https://github.com/gwaithimirdain/narya>`_; in the meantime, you can follow the instructions for :ref:`ProofGeneral mode (manual installation)`.  You will need to repeat this every time Emacs, ProofGeneral, or Narya is updated (at least until the Narya ProofGeneral mode stabilizes and we can get it incorporated in the ProofGeneral distribution).

Finally, you can run

.. code-block:: bash

  emacs

and create or open a ``.ny`` file to start Narya ProofGeneral.

On Windows
^^^^^^^^^^

The easiest way to run Narya on Windows 11 is to use the static binary inside `Windows Subsystem for Linux <https://learn.microsoft.com/en-us/windows/wsl/install>`_.  To install WSL, open a command prompt and run

.. code-block:: none

  wsl --install

After this finishes, you may need to reboot your computer and run the same command again in order to install a Linux distribution inside WSL.  Once WSL is installed, you can run

.. code-block:: none

  wsl

to enter a Linux command prompt, and then follow the Linux instructions above.  If you downloaded the static distribtion in Windows, you can navigate to it in WSL using a path like ``/mnt/c/Users/YOUR NAME/Downloads``.  You can also download it directly from the WSL prompt with

.. code-block:: none

  wget https://gwaithimirdain.github.io/narya/releases/narya-master-static.tar.gz
  tar -xzf narya-master-static.tar.gz
  cd narya-xxxxxxx-YYYYMMDD

(for the appropriate directory name) and then proceed with the above Linux instructions.  Note that when you run Emacs from within WSL, it should automatically pop up as a graphical window.

On Mac
^^^^^^

The static binary does not work on a Mac, but you can compile Narya from source as below.


Compiling from source
---------------------

If the static binary does not work for you, or if you want to edit the Narya code, you will have to compile it yourself.  This requires a recent version of OCaml and various libraries.  Currently Narya is developed with OCaml 5.3.0; as far as I know, it also compiles with any version after 5.2.1, but this is not regularly verified.  The steps to compile Narya are:

1. Install `OCaml <https://ocaml.org/>`_ and its package manager `Opam <https://opam.ocaml.org/>`_.  How to do this this may vary depending on your operating system.  Make sure that the opam bin directory is permanently added to the ``PATH`` in your shell; if you run ``opam init`` (*not* ``opam init -y``) it will offer to do that for you.

2. Set up the OCaml environment and install the Dune build system by running the following commands:

  .. code-block:: bash

    opam switch create 5.3.0
    opam install dune
    eval $(opam env)

  The ``eval`` command is for Unix-like operating systems.  On Windows, replace it by:

  .. code-block:: none

    for /f "tokens=*" %i in ('opam env') do @%i

  or for PowerShell:

  .. code-block:: none

    (& opam env) -split '\r?\n' | ForEach-Object { Invoke-Expression $_ }

3. Download the Narya source code.  If you have (or install) `Git <https://git-scm.com/>`_ you can do this with:

  .. code-block:: bash

    git clone https://github.com/gwaithimirdain/narya.git

  You can also download a `ZIP file <https://github.com/gwaithimirdain/narya/archive/refs/heads/master.zip>`_ and unpack it.

4. Navigate to the root of the Narya source code (e.g. ``cd narya`` or ``cd narya-master``) and run the following commands:

  .. code-block:: bash

    dune build narya.opam
    opam install . --deps-only
    dune build @install
    dune runtest
    dune install

This will make the executable available in a directory such as ``$HOME/.opam/5.3.0/bin``, which should be in your ``PATH`` so that you can run it in the future from any directory by simply typing ``narya``.

Alternatively, instead of running ``dune install``, you can run the executable directly from the Narya source directory with ``dune exec narya``.  In this case, to pass flags to the executable, put them after a ``--``.  For instance, ``dune exec narya -- test.ny -i`` loads the file ``test.ny`` and then enters interactive mode.

If any of the above steps don't work for you, or if you have any other problems or encounter any bugs, please let us know by `opening an issue on GitHub <https://github.com/gwaithimirdain/narya/issues/new/choose>`_.

Compiling with nix
------------------

Narya can also be developed and installed with `Nix <https://nixos.org/>`_.

1. Get a version of nix with `flakes <https://nixos.wiki/wiki/flakes>`_ enabled, for instance via `determinate nix <https://github.com/DeterminateSystems/nix-installer>`_.

2. Run ``nix develop`` to open a shell with all of the necessary dependencies for running ``dune build``. This may ask if you accept using a cache; you can say yes if you want to speed up the build process, or no if you want everything built on your own machine.

3. Run ``nix build`` to build via nix.  On Linux, this will create a static executable that can be copied over to other Linux machines without problems.


ProofGeneral mode (manual installation)
---------------------------------------

The recommended mode of use of Narya is with its `ProofGeneral <https://proofgeneral.github.io/>`_ Emacs mode (for further description of this, see :ref:`ProofGeneral mode`).  Unfortunately, ProofGeneral doesn't make it easy for users to add new proof assistant modes.  The static binary distribution includes a shell script that tries to automate this process, which you can also run from its directory in the source tree:

.. code-block:: bash

  cd dist
  ./install-pg.sh

You will also need to ensure that Emacs can find the Narya executable.  On Linux machines, and in Windows Subsystem for Linux, this should happen automatically as long as the opam directory has been added to your shell profile (as can be done by ``opam init``).  On a Mac, when Emacs is run as a GUI it takes its environment variables from somewhere else; one solution is to install the package `exec-path-from-shell <https://github.com/purcell/exec-path-from-shell>`_.

If th automatic ProofGeneral installer doesn't work for you, you can follow these steps to install Narya's ProofGeneral mode manually.

1. Install `Emacs <https://www.gnu.org/software/emacs/>`_ and ProofGeneral.  The recommended way to install ProofGeneral is from `MELPA <https://melpa.org/>`_ using Emacs' package manager, as described at the `ProofGeneral page <https://proofgeneral.github.io/>`_.

2. Find the ProofGeneral installation directory, which may be something like ``$HOME/.emacs.d/elpa/proof-general-XXXXXXXX-XXXX``.

3. In this directory, create a subdirectory called ``narya`` and copy (or, better, symlink) the files in the proofgeneral directory of the Narya repository into that subdirectory.

4. Then edit the file ``proof-site.el`` in the subdirectory ``generic`` of the ProofGeneral installation directory and add this line line

  .. code-block:: none

    (narya "Narya" "ny" nil (".nyo"))

  to the list of proof assistants in the definition of the variable ``proof-assistant-table-default``.

5. If there is a byte-compiled Emacs Lisp file ``proof-site.elc`` in the ``generic`` directory, either delete it, or re-create it from your edited ``proof-site.el`` using ``M-x byte-compile-file``.

6. Restart Emacs.

You will have to repeat these steps whenever the Narya ProofGeneral mode is updated (unless you symlinked the files instead of copying them, in which case restarting Emacs will suffice); whenever ProofGeneral is updated; and whenever Emacs is updated.  Note also that you can only use ProofGeneral with one proof assistant per Emacs session: if you want to switch between (say) Narya and Rocq, you need to restart Emacs or open a new instance of it.  These appear to be fundamental restrictions of ProofGeneral (if you know how to get around them, please let me know); although once Narya and its ProofGeneral mode are more stable we can probably petition to be added to the main ProofGeneral distribution.


In-browser version
------------------

There is also a version of Narya that compiles to JavaScript and runs in a browser, called jsNarya.  Instructions for compiling and running jsNarya locally can be found in `js/README <https://github.com/gwaithimirdain/narya/blob/master/js/README.md>`_, but a recent version of it can also be accessed directly at `mikeshulman.github.io/jsnarya <https://mikeshulman.github.io/jsnarya>`_, not requiring installing or compiling anything locally.  However, jsNarya is currently limited to the interactive mode with one startup file (:ref:`see here <top-level-interface-jsNarya>`).

Building the Documentation
--------------------------

Before you can build the documentation, ensure you have the following dependencies installed:

1. *Sphinx*: The documentation generator.
2. *Sphinx Read the Docs theme*: A popular theme for Sphinx-based documentation.

To install the dependencies, run the following commands:

.. code-block:: bash
   
   pip install sphinx sphinx-rtd-theme

After installing the required dependencies, navigate to the documentation directory (typically ``docs/`` or ``docs/source/``).

To build the documentation in HTML format, run:

.. code-block:: bash
   
   make html

The output will be saved in the ``_build/html`` directory. You can open ``index.html`` in a browser to view the documentation.

For more advanced configuration, refer to the `Sphinx documentation <https://www.sphinx-doc.org/>`_

