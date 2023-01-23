if !(type "brew" > /dev/null 2>&1); then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> /Users/winky/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
fi

if !(type "ansible" > /dev/null 2>&1); then
  brew install ansible
fi

if [ ! -d $HOME/mac-provisioning ]; then
  git clone https://github.com/winky/mac-provisioning.git $HOME/mac-provisioning
fi
