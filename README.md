# RunScripts

- `/` — 使用说明页（`index.html`）
- `/main.sh` — 脚本本体：`bash <(curl -fsSL https://<当前域名>/main.sh)`

页面用 `location.origin` 自动生成命令地址，本地预览、Pages 预览域名和自定义域名都会自动适配。Cloudflare Pages 直接部署仓库根目录，无需构建命令；`_headers` 保证 `/main.sh` 以纯文本返回。

脚本支持 Alpine Linux（apk + OpenRC）；Alpine 需先 `apk add bash curl`，UFW 位于 community 仓库，脚本会在需要时自动启用。
