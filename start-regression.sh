#!/bin/bash
~/git/CPAN-Testers-Tools/regression.pl        \
  --src /home/david/src/perl-5.10.1/          \
  --old EXODIST/Test-Simple-1.001014.tar.gz   \
  --new EXODIST/Test-Simple-1.301001_104.tar.gz   \
  --dir comparison --list list.txt      \
