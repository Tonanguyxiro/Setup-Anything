# GitHub Authentication

## Fine-Grained Personal Access Token

```shell
# Show the current remotes
git remote -v

# Set the HTTPS remote without a token
git remote set-url origin https://github.com/<Your-Username>/<Your-Repository>.git

# Scope credentials by repository and cache them in memory for eight hours
git config --global credential.https://github.com.useHttpPath true
git config --global credential.helper 'cache --timeout=28800'

# On the first push, enter your username and paste the token at the password prompt
git push
```

Keep the token out of the remote URL and repository. The cache helper stores credentials in memory. Run `git credential-cache exit` to clear the cache immediately.

## Set Your Name and Email

```shell
git config --global user.name "Tong Yuan"
git config --global user.email "yuantong.zj@qq.com"
```
