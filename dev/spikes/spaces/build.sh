#!/bin/sh
set -e
cd "$(dirname "$0")"
clang -fobjc-arc -O1 -Wall -Wno-unused-function -framework AppKit -framework ApplicationServices -framework CoreGraphics spike.m -o spike
