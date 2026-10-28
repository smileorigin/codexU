# Zstandard 解码器

来源：[facebook/zstd v1.5.7](https://github.com/facebook/zstd/tree/v1.5.7)，使用其 BSD 许可证，仅静态编译解压实现

`zstddeclib.c` 由该版本的官方合并脚本生成，没有修改上游算法：

```sh
python3 build/single_file_libs/combine.py -r lib -x legacy/zstd_legacy.h -o zstddeclib.c build/single_file_libs/zstddeclib-in.c
```

校验值（SHA-256）：

| 文件 | 校验值 |
| --- | --- |
| 官方 `zstd-1.5.7.tar.gz` | `eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3` |
| `zstddeclib.c` | `5eb38abe0a7eea13674b312a006df72002d4192f0f0b4d09e6f03fb927a1f3d0` |
| `zstd.h` | `9b4bc8245565c98ccfc61c07749928b57e7c0f6fddb0530c4f6aa1971893d88b` |
| `zstd_errors.h` | `66a8c3f71d12ea6e797e4f622f31f3f8f81c41b36f48cad4f5de7d8bfb6aac0a` |

应用资源同时包含 `Zstandard-LICENSE.txt`，运行时不加载 Homebrew 动态库或外部解压命令
