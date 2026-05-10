# FakeSIP-SelectIP

这是一个基于 [FakeSIP](https://github.com/MikeWang000000/FakeSIP) 的启动脚本，主要目标是：

> **由于UDP的特性，接管整个网络接口偶尔会造成fakeSIP不成功的情况。**

> **让 FakeSIP 只对指定的内网设备 IP 生效，而不是对整个网络接口的所有设备生效，使其提高稳定性。**

本项目尤其适用于以下场景：

- iStoreOS / OpenWrt
- 希望保留原版 FakeSIP 的流量伪装能力，只希望对部分内网设备启用 FakeSIP。

---

## 使用方法
请将该sh脚本运行在同fakesip目录，与udp.payload.bin一起，给脚本权限。

指定IP方法请自行查看sh。

### 添加静默启动：
‍```
sleep 15
sh /root/fakesip-linux-x86_64/FakeSIP_SelectIP.sh 3
‍```
