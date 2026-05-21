FROM n8nio/runners:2.11.1

# 1. 切换到 root 用户以获取安装权限
USER root

# 2. 复制依赖清单
COPY requirements.txt /tmp/requirements.txt

# 3. 执行安装逻辑
RUN set -e; \
    # 定义虚拟环境 Python 路径
    PY_BIN="/opt/runners/task-runner-python/.venv/bin/python"; \
    \
    # 确保 pip 可用并升级到最新版
    $PY_BIN -m ensurepip --upgrade; \
    $PY_BIN -m pip install --no-cache-dir --upgrade pip; \
    \
    # 安装业务依赖
    $PY_BIN -m pip install --no-cache-dir -r /tmp/requirements.txt; \
    \
    # 清理临时文件
    rm /tmp/requirements.txt

# 4. 切换回默认的 runner 用户，确保 n8n 运行安全
USER runner
