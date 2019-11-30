#!/bin/bash

if type "xcode-select" >&- && xpath=$( xcode-select --print-path ) && test -d "${xpath}" && test -x "${xpath}";
then
  echo "Xcode is installed"
fi

if type "pip" > /dev/null 2>&1;
then
  echo "Do find command pip."
else
  echo "Not find command pip!"
  echo "Install pip"
  sudo easy_install pip
fi

sudo pip install -r ./etc/init/requirements.txt
