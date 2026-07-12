#!/usr/bin/env bash

# Example of a script with shellcheck errors fixed and best practices applied

set -euo pipefail

cleanup() {
  echo "Cleaning up..."
}
trap cleanup EXIT

echo "Enter a filename:"
read -r filename

# Fixed SC2086: Quoted variable
# Fixed SC2250: Braces for variable expansion
if [ -f "${filename}" ]; then
  echo "File exists."
else
  echo "File does not exist."
fi

# Fixed SC2006: Used $(...)
current_date=$(date)
echo "Current date: ${current_date}"

# Fixed SC2155: Declared and assigned separately
export PATH
PATH="${PATH}:/custom/bin"
