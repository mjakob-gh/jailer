# jailer

A script to build FreeBSD jails from pkgbase (see https://github.com/mjakob-gh/build-freebsd-system) or basecore (see https://github.com/mjakob-gh/create-basecore-pkg) package(s).

## Installation
Make sure, you have access to a pkgbase and/or basecore repository and it is/they are enabled (```pkg -vv```).
You can, of course, change the names of paths, names, etc. but dont forget to use the correct ones in ```/usr/local/etc/jailer.conf```

clone the repository to the directory jailer:
```shell
git clone https://github.com/mjakob-gh/jailer.git jailer
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
create a dataset for the jails (you can use option ```compress=lz4``` on systems before FreeBSD 13, on newer systems you can use ```compress=zstd``` for better performing compression)
```shell
zfs create -o compress=zstd -o mountpoint=/jails zroot/jails
```
optional: set a sizelimit for the jail dataset
```shell
zfs set quota=250G zroot/jails
```
edit the configuration file and adapt the entries to your environment:
```shell
vi /usr/local/etc/jailer.conf
```

## Usage
for a list of commands and arguments see
```shell
jailer help
```

## Examples
### Create jails
* create a pkgbase jail with the IP and start it directly (```-s```):
```shell
jailer create j1 -i 192.168.0.101 -s
```
* create another pkbase jail with a VNET network (```-v```):
```shell
jailer create j2 -i 192.168.0.102 -s -v
```
* create and start a jail with the basecore (```-m```) pkg:
```shell
jailer create j3 -i 192.168.0.103 -s -m
```
* create and start a basecore jail (```-m```), install (```-P```) and enable (```-e```) the nginx webserver:
```shell
jailer create j4 -i 192.168.0.104 -s -m -P "nginx" -e "nginx"
```
* create and start a basecore jail (```-m```), with a VNET network (```-v```) and the SSH server enabled (```-o```):
```shell
jailer create j5 -i 192.168.0.105 -s -v -m -o
```
### Update jails
* update a jail base (```-b```), the installed packages (```-p```) and restart it:
```shell
jailer update j1 -b -p -s
```
### Destroy jails
* remove a created jail
```shell
jailer destroy j4
```
* list running jails
```shell
jailer list
```
### control jails (```start|stop|restart [jailname]```)
* stop all jails
```shell
jailer stop
```
* stop jail j1
```shell
jailer stop j1
```
* restart jail j2
```shell
jailer restart j2
```