# PostgreSQL 部署手册

> 适用产物：`postgresql-<version>-glibc217-<arch>.tar.gz`
> 兼容：CentOS 7+ / RHEL 7+ / Ubuntu 18.04+ / Debian 10+ / Amazon Linux 2 / SLES 12+
> 架构：x86_64、aarch64

本手册覆盖：
- [一、系统准备](#一系统准备)
- [二、单机部署](#二单机部署)
- [三、主从复制 vs 读写分离（先理清概念）](#三主从复制-vs-读写分离先理清概念)
- [四、主从复制部署（流式复制）](#四主从复制部署流式复制)
- [五、读写分离接入](#五读写分离接入)
- [六、常用扩展启用](#六常用扩展启用)

---

## 一、系统准备

### 1.1 创建系统用户与目录

```bash
# 创建 postgres 用户（无登录 shell 也可，这里给 /bin/bash 便于调试）
useradd -r -m -d /var/lib/pgsql -s /bin/bash postgres

# 准备目录
install -d -o postgres -g postgres -m 0700 /var/lib/pgsql/17/data
install -d -o postgres -g postgres -m 0755 /var/log/pgsql
install -d -o postgres -g postgres -m 0755 /var/run/pgsql
```

### 1.2 解压安装产物

```bash
# 解压到根目录，--strip-components=1 去掉顶层 postgresql-<version>/
tar -xzf postgresql-17.5-glibc217-x86_64.tar.gz -C / --strip-components=1

# 验证二进制位置
ls /usr/local/pgsql/bin/
# initdb  pg_ctl  postgres  psql  pg_basebackup  ...
```

### 1.3 配置动态库查找路径

由于安装到非标准前缀 `/usr/local/pgsql/lib`，需让 ld 知道：

```bash
echo '/usr/local/pgsql/lib' > /etc/ld.so.conf.d/pgsql.conf
ldconfig
```

### 1.4 把 PG 命令加入 PATH（所有用户）

```bash
cat > /etc/profile.d/pgsql.sh <<'EOF'
export PATH=/usr/local/pgsql/bin:$PATH
export MANPATH=/usr/local/pgsql/share/man:$MANPATH
EOF
chmod 644 /etc/profile.d/pgsql.sh
```

---

## 二、单机部署

### 2.1 初始化数据目录

```bash
# 切到 postgres 用户执行
su - postgres -c "/usr/local/pgsql/bin/initdb \
  -D /var/lib/pgsql/17/data \
  -E UTF8 \
  --locale=C.UTF-8 \
  --data-checksums"
```

参数说明：
- `--locale=C.UTF-8`：本产物编译时关闭了 ICU（CentOS 7 自带 libicu 太旧），使用 libc locale。`C.UTF-8` 在所有 glibc 2.17+ 系统都可用，性能也最好。
- `--data-checksums`：开启数据页校验和，发现磁盘损坏。**只能初始化时设置**，事后改要 dump/restore。
- 如需中文排序：用 `--locale=zh_CN.UTF-8`，但需提前在系统装中文 locale（`localedef -i zh_CN -f UTF-8 zh_CN.UTF-8`）。

### 2.2 编辑核心配置

`/var/lib/pgsql/17/data/postgresql.conf`：

```ini
# ---- 连接 ----
listen_addresses = '*'              # 监听所有网卡；只允许内网时换具体 IP
port = 5432
max_connections = 200

# ---- 内存（按机器实际内存调，下列以 16GB 机器为例）----
shared_buffers = 4GB                # 通常机器内存的 1/4
effective_cache_size = 12GB         # 机器内存的 3/4，给优化器估算
work_mem = 32MB                     # 单个查询排序/Hash 的内存
maintenance_work_mem = 512MB        # VACUUM/CREATE INDEX 用

# ---- WAL 与持久化 ----
wal_level = replica                 # 为主从复制留口子（即使先单机也设上）
max_wal_size = 4GB
min_wal_size = 1GB
checkpoint_completion_target = 0.9

# ---- 日志 ----
logging_collector = on
log_directory = '/var/log/pgsql'
log_filename = 'postgresql-%Y-%m-%d.log'
log_rotation_age = 1d
log_rotation_size = 100MB
log_line_prefix = '%t [%p] %u@%d '
log_min_duration_statement = 1000   # 记录 > 1s 的慢 SQL

# ---- 扩展预加载（按需启用 pg_cron 等需要 preload 的扩展）----
shared_preload_libraries = 'pg_stat_statements'
```

`/var/lib/pgsql/17/data/pg_hba.conf`（按需放行 IP 段，**注意收敛**）：

```
# TYPE  DATABASE  USER     ADDRESS          METHOD
local   all       all                       peer
host    all       all      127.0.0.1/32     scram-sha-256
host    all       all      ::1/128          scram-sha-256
host    all       all      10.0.0.0/8       scram-sha-256   # 内网段，按实际改
```

### 2.3 注册 systemd 服务

`/etc/systemd/system/postgresql-17.service`：

```ini
[Unit]
Description=PostgreSQL 17 database server
Documentation=https://www.postgresql.org/docs/17/
After=network.target

[Service]
Type=notify
User=postgres
Group=postgres
Environment=PGDATA=/var/lib/pgsql/17/data
Environment=PG_OOM_ADJUST_FILE=/proc/self/oom_score_adj
Environment=PG_OOM_ADJUST_VALUE=0
ExecStart=/usr/local/pgsql/bin/postgres -D ${PGDATA}
ExecReload=/bin/kill -HUP $MAINPID
KillMode=mixed
KillSignal=SIGINT
TimeoutSec=300
# 调高文件描述符上限
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

启动并开机自启：

```bash
systemctl daemon-reload
systemctl enable --now postgresql-17
systemctl status postgresql-17

# 看日志
journalctl -u postgresql-17 -f
tail -f /var/log/pgsql/postgresql-$(date +%F).log
```

### 2.4 初始化业务账号与库

```bash
# 设置 postgres 超级用户密码
su - postgres -c "psql -c \"ALTER USER postgres WITH PASSWORD 'CHANGE_ME_strong_pwd';\""

# 创建业务库与账号（最小权限示例）
su - postgres <<'SQL'
psql <<'EOF'
CREATE ROLE app_user LOGIN PASSWORD 'CHANGE_ME_app_pwd';
CREATE DATABASE app_db OWNER app_user ENCODING 'UTF8';
\c app_db
GRANT ALL PRIVILEGES ON SCHEMA public TO app_user;
EOF
SQL
```

---

## 三、主从复制 vs 读写分离（先理清概念）

很多人把这两个混着说，但它们是 **两个不同层面** 的事：

| 维度 | 主从复制（Replication） | 读写分离（Read-Write Split） |
|---|---|---|
| **解决什么** | 数据冗余、容灾、可读副本 | 流量路由、读吞吐扩展 |
| **所处层面** | **数据层**：主库把变更同步给从库 | **路由层**：把读 SQL 派发到从库，写 SQL 留给主库 |
| **PG 是否原生支持** | ✅ 内置（流式复制 / 逻辑复制） | ❌ **不支持**，要靠中间件或应用层 |
| **关键技术** | WAL 流复制、`pg_basebackup`、`standby.signal` | pgpool-II / Patroni+HAProxy / 应用代码判断 |
| **依赖关系** | 独立可用 | **必须先有主从复制**，否则没东西可分离 |

**简单说**：
- 主从复制是"**有几台机器，数据怎么同步**"。
- 读写分离是"**有几台机器了，请求该打到哪一台**"。
- 你可以只搞主从（拿从库做容灾 + 离线查询/报表），不一定要做读写分离。

后续小节先把主从立起来，再聊读写分离的接入。

---

## 四、主从复制部署（流式复制）

下面以 1 主 1 从为例，扩展到 1 主 N 从原理一致，重复从库配置即可。

| 角色 | IP（示例） |
|---|---|
| 主库 Primary | 10.0.0.10 |
| 从库 Standby | 10.0.0.11 |

### 4.1 主库（Primary）准备

**步骤 1：在主库 postgresql.conf 增改**

```ini
listen_addresses = '*'
wal_level = replica                 # 单机部分已设
max_wal_senders = 10                # 允许的并发流复制连接数（含 pg_basebackup）
wal_keep_size = 1GB                 # 主库保留多少 WAL 给从库追赶（17 改名，旧名 wal_keep_segments）
hot_standby = on                    # 从库可读
synchronous_commit = on             # 默认；如做同步复制再开 synchronous_standby_names
```

**步骤 2：创建专用复制账号**

```bash
su - postgres -c "psql <<'EOF'
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'CHANGE_ME_repl_pwd';
EOF"
```

**步骤 3：放行从库网段的复制连接（pg_hba.conf）**

```
# TYPE  DATABASE     USER         ADDRESS            METHOD
host    replication  replicator   10.0.0.11/32       scram-sha-256
# 多从库时按需添加更多行
```

**步骤 4：重启主库使配置生效**

```bash
systemctl restart postgresql-17
```

### 4.2 从库（Standby）准备

**步骤 1：在从库节点先完成"系统准备 + 安装"（同 §1）**，但 **不要 initdb**——数据目录要靠 `pg_basebackup` 从主库拉。

**步骤 2：清空数据目录后用 pg_basebackup 拷贝主库基线**

```bash
# 务必以 postgres 用户执行；如果 data 目录已有内容，先清空
su - postgres -c "rm -rf /var/lib/pgsql/17/data/*"

su - postgres -c "PGPASSWORD='CHANGE_ME_repl_pwd' \
  /usr/local/pgsql/bin/pg_basebackup \
    -h 10.0.0.10 -p 5432 -U replicator \
    -D /var/lib/pgsql/17/data \
    -Fp -Xs -P -R \
    --slot=standby1 --create-slot"
```

参数说明：
- `-Fp`：plain 格式，直接铺到目录。
- `-Xs`：流式同时拉 WAL，保证一致性。
- `-R`：自动生成 `standby.signal` 文件并把 `primary_conninfo` 写入 `postgresql.auto.conf`，省去手工配置。
- `--slot=standby1 --create-slot`：**强烈推荐**用复制槽，避免主库 WAL 被回收后从库追不上。每个从库一个独立 slot 名。

**步骤 3：（可选）确认 standby 配置写好了**

```bash
cat /var/lib/pgsql/17/data/postgresql.auto.conf
# primary_conninfo = 'user=replicator password=... host=10.0.0.10 port=5432 ... '
# primary_slot_name = 'standby1'

ls /var/lib/pgsql/17/data/standby.signal
# 这个空文件存在 = 启动时进入 standby 模式
```

**步骤 4：启动从库**

```bash
systemctl enable --now postgresql-17
journalctl -u postgresql-17 -f
# 看到 "database system is ready to accept read-only connections" 即成功
```

### 4.3 验证复制正常

**主库侧**：

```sql
-- 应能看到一行 standby
SELECT client_addr, state, sync_state, write_lag, flush_lag, replay_lag
  FROM pg_stat_replication;

-- 复制槽状态
SELECT slot_name, active, restart_lsn FROM pg_replication_slots;
```

**从库侧**：

```sql
-- true 表示当前在 recovery（即作为从库）
SELECT pg_is_in_recovery();

-- 延迟（秒）
SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())) AS lag_sec;
```

**端到端测试**：在主库写一条，1 秒内能在从库读到。

### 4.4 同步 vs 异步复制（选一个）

默认是 **异步**：主库 commit 不等从库确认，吞吐高、可能丢最近几秒数据。

如果数据不容有失（金融、计费），改成 **同步**：

主库 postgresql.conf：
```ini
synchronous_standby_names = 'FIRST 1 (standby1)'
# 'FIRST 1 (...)' 表示列表里至少 1 个从库确认才返回 commit
```

权衡：从库网络抖动或挂掉，主库写入会被阻塞。生产同步复制建议至少 2 个从库 + `ANY 1 (s1, s2)` 策略避免单点。

### 4.5 故障切换（failover）概要

PG 不内置自动 failover，主流方案：

| 工具 | 定位 | 简介 |
|---|---|---|
| **Patroni** | 推荐 | Python 写的高可用框架，DCS 用 etcd/Consul/ZK，配合 HAProxy 路由 |
| **repmgr** | 老牌 | 命令行工具，需要自己写监控/切换脚本 |
| **pg_auto_failover** | 简单 | Citus 出品，自带 monitor 节点 |

手动切换的最小命令（紧急时备查）：
```bash
# 从库执行：晋升为主库（生成 .signal 文件被消费，退出 recovery）
su - postgres -c "/usr/local/pgsql/bin/pg_ctl promote -D /var/lib/pgsql/17/data"
```
晋升后**原主库不能直接重新加入**，需要 `pg_rewind` 或重做 basebackup。

---

## 五、读写分离接入

主从立起来后，读写分离的关键问题是 **"客户端怎么知道把哪条 SQL 发给哪台"**。三种主流路径：

### 方案 A：应用层路由（最轻量）

代码里维护两个连接池：`primary_pool`、`replica_pool`。明显的写操作（INSERT/UPDATE/DELETE/DDL）走 primary，纯查询走 replica。

- **优点**：零中间件，延迟最低，控制粒度细
- **缺点**：业务代码侵入；事务内的读必须留在主库，框架要支持
- **适合**：已有 ORM/DAL 抽象层的项目（如 Spring Boot 的 `@Transactional(readOnly=true)`、Django 的 database routers）

### 方案 B：pgpool-II（中间件代理）

在主从前面架一个 pgpool-II，它解析 SQL 自动判断读写并路由。

- **优点**：应用零改造，还能做连接池、负载均衡、查询缓存
- **缺点**：pgpool-II 自身是新的单点，部署/调优有学习成本；SQL 解析偶尔会判错
- **典型架构**：`App → pgpool-II → {Primary, Standby1, Standby2}`

### 方案 C：HAProxy + Patroni（云原生友好）

Patroni 维护集群拓扑，HAProxy 暴露两个 endpoint：
- `:5000` 永远指向当前主库（写）
- `:5001` 轮询健康从库（读）

应用按业务语义连不同端口。

- **优点**：和故障切换天然结合，主从角色变了端口照旧
- **缺点**：组件多（etcd + Patroni + HAProxy）

### 哪种该选

| 场景 | 推荐 |
|---|---|
| 团队小、新项目、Spring/Django 等成熟框架 | 方案 A（应用层） |
| 老应用难改、SQL 路由规则简单 | 方案 B（pgpool-II） |
| 已有 K8s/etcd 基础设施、追求高可用 | 方案 C（Patroni + HAProxy） |

**共同陷阱**：
- 从库有复制延迟。**写后立即读**的场景（比如"提交订单后立刻查订单列表"）必须强制路由到主库，否则会读到旧数据。
- 长事务中混合读写要慎重，事务内的读建议都留在主库。

---

## 六、常用扩展启用

本产物包含的扩展（基于 EXTENSIONS.txt）：

```
pg_cron, vector (pgvector), pg_stat_statements, pg_trgm, hstore,
btree_gin, btree_gist, postgres_fdw, pgcrypto, plpython3u,
uuid-ossp, fuzzystrmatch, ltree, intarray, ...
```

### 6.1 直接 `CREATE EXTENSION` 即可的（无 preload 要求）

```sql
CREATE EXTENSION IF NOT EXISTS vector;             -- pgvector，向量检索
CREATE EXTENSION IF NOT EXISTS pg_trgm;            -- 字符串模糊匹配
CREATE EXTENSION IF NOT EXISTS hstore;             -- KV 存储
CREATE EXTENSION IF NOT EXISTS btree_gin;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS postgres_fdw;       -- 跨库查询
CREATE EXTENSION IF NOT EXISTS pgcrypto;           -- 哈希、加密
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
```

### 6.2 需要 `shared_preload_libraries` 的扩展

#### pg_stat_statements（SQL 性能分析）

postgresql.conf：
```ini
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.max = 10000
pg_stat_statements.track = all
```

重启后：
```sql
CREATE EXTENSION pg_stat_statements;

-- 看最耗时的 SQL
SELECT query, calls, total_exec_time, mean_exec_time
  FROM pg_stat_statements
  ORDER BY total_exec_time DESC
  LIMIT 20;
```

#### pg_cron（数据库内定时任务）

postgresql.conf：
```ini
shared_preload_libraries = 'pg_stat_statements,pg_cron'  # 多个用逗号
cron.database_name = 'postgres'    # pg_cron 元数据放哪个库；只能挑一个
```

重启后，在 `cron.database_name` 指定的库里：
```sql
CREATE EXTENSION pg_cron;

-- 每天凌晨 3 点清理 7 天前的日志表
SELECT cron.schedule(
  'cleanup-old-logs',
  '0 3 * * *',
  $$ DELETE FROM logs WHERE created_at < now() - interval '7 days' $$
);

-- 任务定义在 postgres 库，但要操作其他库时
SELECT cron.schedule_in_database(
  'task-name', '*/5 * * * *',
  'VACUUM ANALYZE big_table',
  'app_db'
);
```

**注意**：在主从架构下，从库是只读的，pg_cron 的作业**只能在主库执行**。failover 后 cron 作业会自动跟随新主库（因为元数据也复制过去了）。

---

## 附录：常见问题速查

**Q: 解压后跑 initdb 报 "could not find a /tmp 目录"？**
A: 数据目录权限不对。`chown -R postgres:postgres /var/lib/pgsql && chmod 700 /var/lib/pgsql/17/data`。

**Q: 启动报 "could not load library ...: cannot open shared object file"？**
A: 漏了 ldconfig，执行 `echo /usr/local/pgsql/lib > /etc/ld.so.conf.d/pgsql.conf && ldconfig`。

**Q: 从库追不上、复制中断？**
A: 多半是主库 WAL 被回收。检查 `pg_replication_slots.active` 是否 true、`wal_keep_size` 是否够大、磁盘空间是否够。

**Q: arm64 节点能加入 x86_64 主库的复制集吗？**
A: 可以。流式复制是 WAL 字节级的，PG 数据文件格式跨架构兼容（只要 endianness 同——x86_64 和 aarch64 都是 little-endian）。仍建议生产保持架构一致便于运维。
