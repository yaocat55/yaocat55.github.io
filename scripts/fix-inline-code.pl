#!/usr/bin/perl
# Fix inline code spacing without breaking ``` fences
# Only adds spaces between inline code and adjacent CJK/word chars
while (<>) {
    # Skip code fence lines
    if (/^```/) {
        print;
        next;
    }
    # Add space before opening backtick when preceded by word char
    s/(\w)(`)(\S)/$1 $2$3/g;
    # Add space after closing backtick when followed by word char
    s/(\S)(`)(\w)/$1 $2 $3/g;
    print;
}
