# iOS 包版本维护

设置顶部的“关于”直接展示当前安装包的版本与构建号，分别读取 `CFBundleShortVersionString`、`CFBundleVersion`。界面不写死版本，诊断区不再重复藏一份。

`apps/ios-conversation/Configuration/Version.xcconfig` 是唯一版本来源，Debug、Release、DeviceTrial 共用。正式版本使用三段数字；构建号使用递增的正整数，正式版本变化也不重置。

准备交付新包时，在冻结输入前执行一次：

```sh
python3 apps/ios-conversation/Scripts/app-version.py bump
```

若要同时更新正式版本，使用下面这一条替代上面的命令：

```sh
python3 apps/ios-conversation/Scripts/app-version.py bump --version 0.3.1
```

合入候选前先核对最新已交付包和并行候选占用的构建号，保留较大值再递增，不把另一工作树的旧值当全局最新。同一冻结候选因工具故障重试可复用原构建号；产品字节变化后再次交付须递增。普通本地编译不自动加号。禁止用 Xcode 参数覆盖版本或单改 DeviceTrial。

Xcode 的 `Check App Version` 阶段与已有工程校验器检查配置继承、版本格式及覆盖，不一致会阻止构建。包生成后核对包内实际值：

```sh
python3 apps/ios-conversation/Scripts/app-version.py check --app /absolute/path/CatpawM.app
```

日期交付证据继续保存源码 commit、正式版本、构建号和包指纹；安装后从系统包信息及设置读回同一值。当前进度只维护 master-plan，不把本页作为发布清单。旧包与证据保留；源码版本调整不授权手机安装、部署或发布。
