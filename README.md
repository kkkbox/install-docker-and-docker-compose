

## 运行方法

普通用户通过 `sudo` 执行，脚本会将该用户加入 `docker` 组：

```bash
sudo bash install-docker.sh
```

如果直接使用 root 登录，指定需要添加的用户：

```bash
DOCKER_USER=你的用户名 bash install-docker.sh
```

不运行 `hello-world` 网络测试：

```bash
sudo RUN_TEST=0 bash install-docker.sh
```

注意：这里保留了你原来的 GitHub 手动下载 Compose 方式，因此以后升级 Compose 需要重新下载。Docker 官方也支持通过 `docker-compose-plugin` 软件包安装并由 APT 管理更新，但那种方式不使用你指定的 GitHub 加速地址。 [docs.docker](https://docs.docker.com/engine/install/debian/)

Docker,Docker Compose,一键安装脚本,支持最新Debian13正式版
```bash
curl -fSLO https://v4.gh-proxy/https://raw.githubusercontent.com/kkkbox/install-docker-and-docker-compose/main/install-docker.sh && chmod +x install-docker.sh && bash install-docker.sh
```
