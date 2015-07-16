#!/bin/sh
#: Build binary distributions of MyPaint for Windows from git.
#:
#: Usage:
#:   $ windows/build.sh [OPTIONS]
#:
#: Options:
#:   --help         show this message and exit ok
#:   --sloppy       skip tests, no cleanup, reuse existing target areas
#:   --show-output  open output folder in Windows if build succeeded
#:
#: Rigourous builds (--sloppy flag not specified) are our standard for
#: release, and are the default, but the amount of reinstallation and
#: rebuilding they involve can be tedious for repeated testing.
#:
#: If you have Inno Setup installed, its ISCC.exe will be called with an
#: auto-generated .iss script to make a user-friendly setup.exe in
#: addition to the standalone .zip.
#:
#: Final output is written into a temp folder, and if the --showoutput
#: flag is specified on the command line, Windows Explorer is launched
#: on it so you can copy the .zip and .exe files somewhere else.
#:
#: You MUST install MSYS2 <https://msys2.github.io/> before running this
#: script, and it MUST be run from either the MINGW32 or MINGW64 shell.

set -e

RIGOUROUS=true
SHOW_OUTPUT=false

while test $# -gt 0; do
    case "$1" in
        --help)
            grep '^#:' $0
            exit 0
            ;;
        --sloppy)
            RIGOUROUS=false
            shift
            ;;
        --show-output)
            SHOW_OUTPUT=true
            shift
            ;;
    esac
done
if test $# -gt 0; then
    echo >&2 "Trailing junk in args: \"$@\" (try running with --help)"
    exit 1
fi


# Use the git revision and MSYSTEM architecture to distinguish one
# build area from another.

case "x$MSYSTEM" in
    xMINGW32)
        ARCH="i686"
        BITS=32
        ;;
    xMINGW64)
        ARCH="x86_64"
        BITS=64
        ;;
    *)
        echo "*** Unsupported build system ***"
        echo "This script must be run in the MINGW32 or MINGW64 environment"
        echo "that comes with MSYS2."
        exit 2
        ;;
esac
GITREV=`git rev-parse --short HEAD`


# Satisfy build dependencies.
# Make sure the build will use the most recent toolchain.

{
    echo "+++ Installing toolchain and build deps into your $MSYSTEM ..."
    pacman -Sy
    pacman -S --noconfirm --needed \
        mingw-w64-$ARCH-toolchain \
        mingw-w64-$ARCH-pkg-config \
        mingw-w64-$ARCH-gtk3 \
        mingw-w64-$ARCH-json-c \
        mingw-w64-$ARCH-lcms2 \
        mingw-w64-$ARCH-python2-cairo \
        mingw-w64-$ARCH-pygobject-devel \
        mingw-w64-$ARCH-python2-gobject \
        mingw-w64-$ARCH-python2-numpy \
        mingw-w64-$ARCH-hicolor-icon-theme \
        mingw-w64-$ARCH-librsvg
    echo "+++ Installing other required tools..."
    pacman -S --noconfirm --needed \
        zip \
        git \
        tar \
        xz
}


# Export and unpack pristine tagged source into a temp area,
# where the build will take place.

BUILD_ROOT="/tmp/mypaint-builds/${GITREV}-${ARCH}"
TMP_ROOT="${BUILD_ROOT}/tmp"
SRC_DIR="${TMP_ROOT}/src"

{
    echo "+++ Exporting source..."
    tarball="$TMP_ROOT"/mypaint.tar.xz
    if ! test -f "$tarball"; then
        mkdir -p "$TMP_ROOT"
        # No git checks because permission semantics differences
        # on permission bits we're using to turn off tests (ugh!)
        # mean spurious `git diff` output on Windows.
        release_opts="--simple-naming --headless --no-gitcheck"
        if ! $RIGOUROUS; then
            release_opts="--no-tests $release_opts"
        fi
        ./release.sh $release_opts -- "$TMP_ROOT"
    fi
    if ! test -f "$tarball"; then
        echo "*** Tarball $tarball was not created by release.sh"
        exit 2
    fi
    if $RIGOUROUS || ! test -d "$SRC_DIR"; then
        rm -fr "$SRC_DIR"
        mkdir -p "$SRC_DIR"
        (cd "$SRC_DIR" && tar x --strip-components=1 -pf "$tarball")
    fi
    . "$SRC_DIR/release_info"
    if test "x$MYPAINT_VERSION_FORMAL" = "x"; then
        echo "*** $SRC_DIR/release_info did not define MYPAINT_VERSON_FORMAL"
        exit 2
    fi
    echo "+++ Exported $MYPAINT_VERSION_FORMAL"
}



# Begin making a standalone target root folder which will contain a
# mingwXX prefix area as a subdirectory. This will be zipped up as the
# standalone distribution, and later forms the source folder for the
# installer distribution

DIST_BASENAME="mypaint-w${BITS}-${MYPAINT_VERSION_FORMAL}"
TARGET_DIR="${BUILD_ROOT}/${DIST_BASENAME}"
PREFIX="${TARGET_DIR}/mingw${BITS}"

{
    echo "+++ Installing runtime dependencies into target..."
    if $RIGOUROUS; then
        rm -fr "$TARGET_DIR"
    fi
    mkdir -vp "$TARGET_DIR"
    # Set up pacman so it can deploy stuff
    mkdir -vp "$TARGET_DIR/var/lib/pacman"
    mkdir -vp "$TARGET_DIR/var/log"
    mkdir -vp "$TARGET_DIR/tmp"
    pacman -Sy --root "$TARGET_DIR"
    # Alias to simplify things
    pacman_s="pacman -S --root $TARGET_DIR --needed --noconfirm"
    # Need all of numpy
    $pacman_s "mingw-w64-${ARCH}-python2" \
        "mingw-w64-$ARCH-python2-numpy"
    # Avoid a big Perl dep by just installing the icon files
    $pacman_s --assume-installed mingw-w64-$ARCH-icon-naming-utils \
              --ignoregroup mingw-w64-$ARCH-toolchain \
        "mingw-w64-$ARCH-adwaita-icon-theme"
    # A subset of the "toolchain" group: runtime stuff only, ideally
    $pacman_s \
        "mingw-w64-$ARCH-gcc-libs"
    # Things that depend on the "toolchain" group subset above
    # but which may try to pull in more (avoid that)
    $pacman_s --ignoregroup mingw-w64-$ARCH-toolchain \
              --assume-installed mingw-w64-$ARCH-python3 \
        "mingw-w64-$ARCH-json-c" \
        "mingw-w64-$ARCH-lcms2" \
        "mingw-w64-$ARCH-python2-cairo" \
        "mingw-w64-$ARCH-python2-gobject" \
        "mingw-w64-$ARCH-librsvg" \
        "mingw-w64-$ARCH-gtk3"
    # GSettings runtime requirements
    $pacman_s "mingw-w64-$ARCH-gsettings-desktop-schemas"
}


# Install the build of MyPaint
{
    echo "+++ Installing MyPaint into the standalone target..."
    (cd $SRC_DIR && scons prefix="$PREFIX" install)
    # Launcher scripts
    cp -v "windows/mypaint-standalone.cmd" "$TARGET_DIR/mypaint.cmd"
    cp -v "windows/mypaint-bin.cmd" "$PREFIX/bin/mypaint.cmd"
    # Icons
    cp -v "desktop/mypaint.ico" "$TARGET_DIR/"
    cp -v "desktop/mypaint.ico" "$PREFIX/share/mypaint/"
    # Licenses
    mkdir -p "$PREFIX/share/licenses/mypaint"
    cp -v "COPYING" "$PREFIX/share/licenses/mypaint"
    cp -v "LICENSE" "$PREFIX/share/licenses/mypaint"
    mkdir -p "$PREFIX/share/licenses/libmypaint"
    cp -v "brushlib/COPYING" "$PREFIX/share/licenses/libmypaint"
}


# Clean up the target - pacman will have pulled in way too much
{
    echo "+++ Pruning unnecessary files and folders from the target..."
    echo -n "Install size before pruning: "
    du -sh "$TARGET_DIR"

    # Docs for non-user-facing things
    rm -fr "$PREFIX"/share/man
    rm -fr "$PREFIX"/share/gtk-doc
    rm -fr "$PREFIX"/share/doc
    rm -fr "$PREFIX"/share/info

    # TCL/tk
    rm -fr "$PREFIX"/lib/tk*
    rm -fr "$PREFIX"/lib/tcl*
    rm -fr "$PREFIX"/lib/itcl*

    # Stuff that's really part of a build environment
    rm -fr "$PREFIX"/share/include
    rm -fr "$PREFIX"/include
    find "$PREFIX"/lib -type f -iname '*.a' -exec rm -f {} \;
    rm -fr "$PREFIX"/lib/python2.7/test
    rm -fr "$PREFIX"/lib/cmake
    rm -fr "$PREFIX"/share/aclocal
    rm -fr "$PREFIX"/share/pkgconfig

    # Remove some FreeDesktop and GNOME things
    rm -fr "$PREFIX"/share/applications
    rm -fr "$PREFIX"/share/appdata
    rm -fr "$PREFIX"/share/mime

    # Other stuff that's not relevant when running on Windows
    rm -fr "$PREFIX"/share/bash-completion
    rm -fr "$PREFIX"/share/readline
    rm -fr "$PREFIX"/share/fontconfig
    rm -fr "$PREFIX"/share/vala
    rm -fr "$PREFIX"/share/thumbnailers   # our fault
    rm -fr "$PREFIX"/share/xml/fontconfig

    # Strip debugging symbols.
    find "$PREFIX" -type f -name "*.exe" -exec strip {} \;
    find "$PREFIX" -type f -name "*.dll" -exec strip {} \;
    find "$PREFIX" -type f -name "*.pyd" -exec strip {} \;

    # .pyc bytecode is unnecessary when running with -OO as we do.
    # find "$PREFIX" -type f -name '*.pyc' -exec rm -f {} \;

    # Terminfo is a fairly big db, and we don't need it for MyPaint.
    rm -fr "$PREFIX"/share/terminfo
    rm -fr "$PREFIX"/lib/terminfo

    # Random binaries which aren't going to be invoked. Hopefully.
    find "$PREFIX"/bin -type f \
        -not -iname '*.dll' \
        -not -iname 'python2w.exe' \
        -not -iname 'gdk-pixbuf-query-loaders.exe' \
        -not -iname 'glib-compile-schemas.exe' \
        -not -iname 'mypaint*' \
        -exec rm -f {} \;

    rm -fr "$TARGET_DIR"/tmp
    if $RIGOUROUS; then
        rm -fr "$TARGET_DIR"/var
    fi
    echo -n "Install size after pruning: "
    du -sh "$TARGET_DIR"
}


# Create a standalone zip bundle while the tree is still pristine

{
    echo "+++ Writing standalone zipfile..."
    (cd ${BUILD_ROOT} && zip -qXr "${DIST_BASENAME}".zip "$DIST_BASENAME")
    echo "+++ Created ${DIST_BASENAME}.zip"
}


# Create an Inno Setup compiler script, and start it

{
    echo "+++ Making Inno Setup script..."
    cp -v windows/postinst.cmd "$PREFIX/bin/mypaint-postinst.cmd"
    iss_in="windows/mypaint.iss.in"
    iss="$TARGET_DIR/mypaint.iss"
    cp -v "$iss_in" "$iss"
    sed -i "s|@VERSION@|$MYPAINT_VERSION_FORMAL|g" "$iss"
    sed -i "s|@BITS@|$BITS|g" "$iss"
}

{
    echo "+++ Running the Inno Setup ISCC tool to make a setup.exe..."
    PATH="/c/Program Files (x86)/Inno Setup 5:$PATH"
    if ( cd "$TARGET_DIR" && exec ISCC.exe mypaint.iss ); then
        echo "+++ ISCC ran successfully"
    else
        echo "*** ISCC failed, see terminal output for details"
        echo "*** (you may need to add the folder with ISCC.exe to your path)"
    fi
}


# Show the output folder if requested

{
    echo "+++ All done."
    echo "+++ Output can be found in $BUILD_ROOT"
    if $SHOW_OUTPUT; then
        echo "+++ Opening build output folder (--show-output)..."
        start "$BUILD_ROOT"
    fi
}

