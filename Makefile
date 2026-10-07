.PHONY: all build release test check bindings package bump-version cli clean help

# 默认架构：universal（Intel + Apple Silicon 通用版），可覆盖为 arm64 / x86_64
ARCH ?= universal

ifeq ($(ARCH),arm64)
RUST_TARGET := aarch64-apple-darwin
else ifeq ($(ARCH),x86_64)
RUST_TARGET := x86_64-apple-darwin
else ifeq ($(ARCH),universal)
# universal 由 scripts/build.sh 内部 lipo 合并双架构；
# 此处 RUST_TARGET 仅作为 test/cli 等单架构目标的原生回退
RUST_TARGET := aarch64-apple-darwin
else
$(error 不支持的架构: $(ARCH)，仅支持 arm64 / x86_64 / universal)
endif

all: build

help:
	@echo "Lokii 构建命令:"
	@echo "  make build [ARCH=...]    - 编译 Debug 版本 (默认: $(ARCH))"
	@echo "  make release [ARCH=...]  - 编译 Release 版本 (默认: $(ARCH))"
	@echo "  make bindings [ARCH=...] - 编译 Rust 核心并生成 UniFFI Swift 绑定"
	@echo "  make test [ARCH=...]     - 运行 Rust 核心单测与 Swift 编译校验"
	@echo "  make check [ARCH=...]    - 运行 Rust 核心静态类型与目标检查"
	@echo "  make package [ARCH=...]  - 打包构建 macOS DMG 安装镜像 (支持 arm64 / x86_64 / universal)"
	@echo "  make cli [ARCH=...]      - 编译命令行搜索工具 (target/$(RUST_TARGET)/release/lokii)"
	@echo "  make bump-version V=...  - 更新项目全量版本号 (如: make bump-version V=0.1.0)"
	@echo "  make clean               - 清理构建产物与临时文件"

bindings:
	@./scripts/build.sh bindings --arch=$(ARCH)

build:
	@./scripts/build.sh app --arch=$(ARCH) --debug

release:
	@./scripts/build.sh app --arch=$(ARCH) --release

test: bindings
	@cargo test --workspace --target $(RUST_TARGET)
	@cd Lokii && LOKII_RUST_TARGET=$(RUST_TARGET) swift build --arch $(ARCH)

check:
	@cargo check --workspace --all-targets --target $(RUST_TARGET)

package:
	@./scripts/build.sh dmg --arch=$(ARCH)

cli:
	@cargo build -p lokii-core --bin lokii --release --target $(RUST_TARGET)
	@echo "==> CLI 已构建: target/$(RUST_TARGET)/release/lokii"
	@echo "    试用: target/$(RUST_TARGET)/release/lokii --help"

bump-version:
	@if [ -z "$(V)" ]; then echo "错误: 请指定版本号，例如: make bump-version V=0.1.0"; exit 1; fi
	@./scripts/build.sh bump-version $(V)

clean:
	@cargo clean
	@cd Lokii && swift package clean
	@rm -rf output
