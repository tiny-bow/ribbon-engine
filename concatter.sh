#!/bin/bash

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 file1 [file2 ... fileN]"
  exit 1
fi

output="concatted.md"

> "$output"

for file in "$@"; do
  if [ -f "$file" ]; then
    echo -e "\n\n\`$file\`\n\`\`\`zig\n" >> "$output"
    cat "$file" >> "$output"
    echo -e "\n\`\`\`\n" >> "$output"
  else
    echo "Warning: $file does not exist or is not a regular file."
  fi
done

echo "Files concatenated into $output"