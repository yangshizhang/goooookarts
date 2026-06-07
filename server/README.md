# GoKartARLine Online Server

无第三方运行时依赖的 Node.js 服务端，同一端口提供：

- `TCP/HTTP 16781`：API、地图分享、排行榜、后端配置页。
- `UDP 16781`：圈速遥测 JSON 数据包，支持 `ping` 和 `lap`。

## API

- `POST /api/auth/request-code`：请求邮箱验证码。
- `POST /api/auth/register`：使用用户名、密码、邮箱、验证码注册。
- `POST /api/auth/login`：登录并获取 Bearer token。
- `GET /api/tracks`：获取已验证的真卡丁车场分享列表。
- `POST /api/tracks`：上传赛道，服务端校验闭合度、长度、范围和弯道特征。
- `GET /api/tracks/:id/download`：下载赛道 JSON。
- `POST /api/tracks/:id/laps`：上传圈速、GPS、加速度、行车线偏离采样，自动优化服务器赛道并返回提升建议。
- `GET /api/tracks/:id/leaderboard`：返回前十排行榜，并包含油门、刹车、平顺性、行车线偏离摘要。

## 部署

```bash
cd server
sudo bash install.sh
```

管理页：`http://服务器地址:16781/admin`。Basic Auth 用户名为 `admin`；默认密码来自 `ADMIN_PASSWORD` 环境变量，未设置时为 `change-me-now`，上线后必须在管理页修改。
