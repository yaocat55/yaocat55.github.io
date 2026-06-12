#!/usr/bin/env perl
use strict;
use warnings;
use open qw(:std :encoding(UTF-8));

while (<>) {
    # Add space after closing backtick before fullwidth punctuation and dashes
    s/`([^`\n]+)`(\x{FF0C}|\x{3002}|\x{FF1A}|\x{FF1B}|\x{FF01}|\x{FF1F}|\x{3001}|\x{FF08}|\x{FF09}|\x{2014}|\x{2013}|\x{2015})/`$1` $2/g;
    # Add space before opening backtick after fullwidth punctuation and dashes
    s/(\x{FF0C}|\x{3002}|\x{FF1A}|\x{FF1B}|\x{FF01}|\x{FF1F}|\x{3001}|\x{FF08}|\x{FF09}|\x{2014}|\x{2013}|\x{2015})`([^`\n]+)`/$1 `$2`/g;
    print;
}
