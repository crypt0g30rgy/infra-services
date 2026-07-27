# Infra SetUp

## Current: 2025-12-06T11:37:09.316Z

- raspberry pi5 single node [16gb]
- hp amd64 pc [32gb]

## Specs

### HP-AMD64

```bash
.-/+oossssoo+/-.               k8s-prod@hp-amd64-k8s
`:+ssssssssssssssssss+:`           ---------------------
-+ssssssssssssssssssyyssss+-         OS: Ubuntu 24.04.4 LTS x86_64
.ossssssssssssssssssdMMMNysssso.       Host: HP ProDesk 400 G6 MT SBKPFV3
/ssssssssssshdmmNNmmyNMMMMhssssss/      Kernel: 6.8.0-117-generic
+ssssssssshmydMMMMMMMNddddyssssssss+     Uptime: 1 min
/sssssssshNMMMyhhyyyyhmNMMMNhssssssss/    Packages: 1056 (dpkg)
.ssssssssdMMMNhsssssssssshNMMMdssssssss.   Shell: bash 5.2.21
+sssshhhyNMMNyssssssssssssyNMMMysssssss+   Terminal: /dev/pts/0
ossyNMMMNyMMhsssssssssssssshmmmhssssssso   CPU: Intel i7-9700 (8) @ 4.700GHz
ossyNMMMNyMMhsssssssssssssshmmmhssssssso   GPU: NVIDIA GeForce GTX 1050 Ti
+sssshhhyNMMNyssssssssssssyNMMMysssssss+   GPU: Intel CoffeeLake-S GT2 [UHD Graphics 630]
.ssssssssdMMMNhsssssssssshNMMMdssssssss.   Memory: 582MiB / 39952MiB
/sssssssshNMMMyhhyyyyhdNMMMNhssssssss/
+sssssssssdmydMMMMMMMMddddyssssssss+
/ssssssssssshdmNNNNmyNMMMMhssssss/
.ossssssssssssssssssdMMMNysssso.
-+sssssssssssssssssyyyssss+-
`:+ssssssssssssssssss+:`
.-/+oossssoo+/-.
```

### PI5-ARM64

```bash
.-/+oossssoo+/-.               w3b@pi-5-16gb-srv-0
`:+ssssssssssssssssss+:`           -------------------
-+ssssssssssssssssssyyssss+-         OS: Ubuntu 24.04.4 LTS aarch64
.ossssssssssssssssssdMMMNysssso.       Host: Raspberry Pi 5 Model B Rev 1.1
/ssssssssssshdmmNNmmyNMMMMhssssss/      Kernel: 6.8.0-1057-raspi
+ssssssssshmydMMMMMMMNddddyssssssss+     Uptime: 18 hours, 26 mins
/sssssssshNMMMyhhyyyyhmNMMMNhssssssss/    Packages: 836 (dpkg), 5 (snap)
.ssssssssdMMMNhsssssssssshNMMMdssssssss.   Shell: fish 3.7.0
+sssshhhyNMMNyssssssssssssyNMMMysssssss+   Terminal: /dev/pts/0
ossyNMMMNyMMhsssssssssssssshmmmhssssssso   CPU: (4) @ 2.400GHz
ossyNMMMNyMMhsssssssssssssshmmmhssssssso   Memory: 4991MiB / 15973MiB
+sssshhhyNMMNyssssssssssssyNMMMysssssss+
.ssssssssdMMMNhsssssssssshNMMMdssssssss.
/sssssssshNMMMyhhyyyyhdNMMMNhssssssss/
+sssssssssdmydMMMMMMMMddddyssssssss+
/ssssssssssshdmNNNNmyNMMMMhssssss/
.ossssssssssssssssssdMMMNysssso.
-+sssssssssssssssssyyyssss+-
`:+ssssssssssssssssss+:`
.-/+oossssoo+/-.
```

## UpComming

- 3 hp elitedesk/prodesk - 3 ha cluster 