#!/bin/bash
# Xcode build phase: copies the Python standard library, our bridge module and
# yt-dlp into Folio.app, and turns Python's binary modules into frameworks
# (the only way iOS allows them to be loaded).
set -e

if [ ! -d "$PROJECT_DIR/Python.xcframework" ]; then
  echo "error: Python.xcframework is missing. Run scripts/fetch_python.sh first."
  exit 1
fi

# Unsigned CI builds: sign the generated frameworks ad hoc (Sideloadly re-signs everything)
if [ -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  export EXPANDED_CODE_SIGN_IDENTITY="-"
fi

source "$PROJECT_DIR/Python.xcframework/build/utils.sh"

install_stdlib Python.xcframework
PYTHON_VER=$(ls -1 "$CODESIGNING_FOLDER_PATH/python/lib" | grep -E "^python3\.[0-9]+$")
PYLIB="$CODESIGNING_FOLDER_PATH/python/lib/$PYTHON_VER"

# Trim parts of the standard library an app never uses (~40 MB)
rm -rf "$PYLIB/test" "$PYLIB/idlelib" "$PYLIB/tkinter" "$PYLIB/turtledemo" \
       "$PYLIB/ensurepip" "$PYLIB/pydoc_data" "$PYLIB/lib2to3" "$PYLIB/unittest/test" \
       "$PYLIB/turtle.py" "$PYLIB/__phello__"
find "$PYLIB/lib-dynload" \( -name "_test*" -o -name "_ctypes_test*" -o -name "xx*" \
       -o -name "_xx*" -o -name "_interp*" \) -delete
find "$PYLIB" -name "__pycache__" -type d -prune -exec rm -rf {} +

# Our code and the installed packages
rsync -a --delete --exclude "__pycache__" "$PROJECT_DIR/Python/app/" "$CODESIGNING_FOLDER_PATH/app/"
rsync -a --delete --exclude "__pycache__" "$PROJECT_DIR/Python/app_packages/" "$CODESIGNING_FOLDER_PATH/app_packages/"

process_dylibs Python.xcframework "python/lib/$PYTHON_VER/lib-dynload"
