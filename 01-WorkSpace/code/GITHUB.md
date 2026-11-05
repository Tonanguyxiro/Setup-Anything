# 配置 Github 登录

### Git & Github

#### Fine-Grained Access Key

```shell
# 查看地址
git remote -v

# 使用不含 Token 的 HTTPS 地址
git remote set-url origin https://github.com/<Your-Username>/<Your-Repository>.git

# 按仓库路径区分 GitHub 凭据，并在内存中缓存 8 小时
git config --global credential.https://github.com.useHttpPath true
git config --global credential.helper 'cache --timeout=28800'

# 首次推送时输入 GitHub 用户名，并在 Password 提示处粘贴 Token
git push
```

不要将 Fine-grained personal access token 写入 remote URL 或提交到仓库。`credential.helper cache` 只在内存中保存凭据；执行 `git credential-cache exit` 可以立即清除缓存。

#### Set User Name & Email

```shell
git config --global user.name "Tong Yuan"
git config --global user.email "yuantong.zj@qq.com"
```
