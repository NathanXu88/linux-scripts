# Realm 管理脚本

交互式管理 [realm](https://github.com/zhboner/realm) TCP/UDP 端口转发。参考了 [EZrealm 菜单](https://github.com/qqrrooty/EZrealm)，脚本独立实现。

## 环境和使用

需要 Linux、systemd、root 权限、Python 3.11+、curl 和 tar，支持 x86_64、aarch64。下载本仓库的 `realm.sh` 后，在服务器运行：

```bash
chmod +x realm.sh
sudo ./realm.sh
```

先选择安装，再添加规则，最后选择启动并开机自启。监听地址为 `[::]:端口`，默认启用 TCP 和 UDP；IPv4 是否同时监听取决于系统的 IPv6 设置。按需要在服务器和云厂商防火墙放行端口。目标支持域名、IPv4 和 IPv6。

配置及程序保存在 `/opt/realm-manager`，服务名为 `realm-manager`。本工具不自动迁移其他 realm 安装。查看日志：

```bash
sudo journalctl -u realm-manager -n 100 --no-pager
```

每次安装时，脚本通过 GitHub API 查询上游最新稳定版，并下载对应架构的安装包；需要能够访问 GitHub API 和下载地址。已经安装的 Realm 不会自动升级，升级需先备份配置。修改规则时若运行中的服务重启失败会尝试恢复原配置；卸载会删除本工具的配置，请提前备份。请先在测试服务器验证再用于生产环境。
