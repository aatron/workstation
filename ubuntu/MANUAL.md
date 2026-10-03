# Ubuntu Set-up

## Install

```bash
sudo apt install -y git
git clone https://github.com/aatron/workstation.git
./workstation/ubuntu/install.sh
```

## Sign-ins

Open a **new terminal** and paste:

```bash
{
read -rp "Git name: " name && git config --global user.name "$name"
read -rp "Git email: " email && git config --global user.email "$email"
agent login
claude   # sign in, then /exit
read -rp "Quit Firefox, then press Enter "
setsid -f cursor >/dev/null 2>&1
setsid -f firefox about:policies https://kagi.com/signin >/dev/null 2>&1
}
```

Then finish by hand:

- [ ] Cursor: sign in
- [ ] Firefox: `about:policies` shows Kagi and LastPass as active
- [ ] Kagi: sign in (tab already open)
- [ ] LastPass: sign in from the toolbar icon
