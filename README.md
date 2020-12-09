# jailer

A script to build FreeBSD jails from pkgbase (see https://github.com/mjakob-gh/build-freebsd-system) or basecore (see https://github.com/mjakob-gh/create-basecore-pkg).

## Installation
Make sure, you have access to a pkgbase and/or basecore repository an it is/they are enabled (```pkg -vv```).
You can, of course, change the names of paths, names, etc. but dont forget to use the correct ones in ```/usr/local/etc/jailer.conf```

clone the repository to the directory jailer:
```shell
git clone https://github.com/mjakob-gh/jailer.git .
```
copy files an directories to their places:
```shell
cd jailer
cp jailer.sh /usr/local/sbin/jailer
chown root:root /usr/local/sbin/jailer
chmod 755 /usr/local/sbin/jailer
cp ./usr/local/etc/jailer.conf  /usr/local/etc/jailer.conf
cp -a ./usr/local/share/jailer/ /usr/local/share/jailer/
```
create a dataset for the jails
```shell
zfs create -o compress=lz4 -o mountpoint=/jails zroot/jails
```
edit the configuration file and change the entries to your environment:
```shell
vi /usr/local/etc/jailer.conf
```

## Usage
for a list of commands and arguments see
```shell
jailer help
```

## Examples
create a pkgbase jail with the IP and start it directly (```-s```):
```shell
jailer create j1 -i 192.168.0.101 -s
```
create another pkbase jail with a VNET network (```-v```):
```shell
jailer create j2 -i 192.168.0.102 -s -v
```
create and start a jail with the basecore (```-m```) pkg:
```shell
jailer create j3 -i 192.168.0.103 -s -m
```
create and start a basecore jail, install (```-P) and enable (```-e```) the nginx webserver:
```shell
jailer create j4 -i 192.168.0.104 -s -m -P "nginx" -e "nginx"
```
update a jail base (```-b```), installed packages (```-p```) and restart it:
```shell
jailer update j1 -b -p -s
```
remove a created jail:
```shell
jailer destroy j4
```
list running jails
```shell
jailer list
```
control jails (```start|stop|restart [jailname]```)
stop all:
```shell
jailer stop
```
stop jail j1
```shell
jailer stop j1
```
restart jail j2
```shell
jailer restart j2
```
