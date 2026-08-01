# SSH 认证与密钥管理设计

## 目标

将主机认证收敛为两种清晰的方式：服务器密码和 SSH 密钥。移除“密钥 + 密码短语”这一容易误解、当前也未完整接入的认证分支；补齐密钥资产的生成、导入、导出、查看、复制与删除闭环，并让新建服务器可以直接选择密钥管家中的已有密钥。

## 产品与交互

### 主机认证

- 认证方式只显示“密码”和“密钥”。
- 选择“密码”时显示服务器登录密码输入框。
- 选择“密钥”时显示已有密钥选择器；没有密钥时提供进入密钥管家的入口。
- 不在主机表单中显示 passphrase 字段，也不把私钥解锁短语当作服务器登录凭据。
- 本期不支持带 passphrase 的加密私钥：导入时直接拒绝并提示“暂不支持带密码短语的加密私钥”，不在内存外保存或询问解锁短语。
- 密钥认证失败时沿用统一的连接失败与重试交互，并明确提示检查密钥是否部署到目标用户的 `authorized_keys`。

### 密钥管家

采用紧凑列表布局，和命令/分组列表保持一致：

- 页面内容区只展示密钥列表；新增入口放在导航栏右上角，使用系统 toolbar 按钮。
- 每行展示名称、算法、指纹摘要、使用中的主机数和进入详情的箭头。
- 点击进入详情；长按打开复制公钥、导出、删除等操作。
- 空状态居中展示，并提供“生成密钥”和“导入密钥”入口。

详情页包含：名称、算法、指纹、公钥文本、使用中的主机列表，以及复制公钥、复制指纹、导出公钥、导出私钥、删除。

生成与导入使用统一表单：

- 算法：软件 Ed25519、RSA 4096、ECDSA P-256。Secure Enclave P-256 明确延期：本期不生成、不导入、不选择、不认证，也不在密钥列表展示；遇到旧的 `se_p256` 记录时返回数据错误并要求重新创建。这样本期三种算法都具备统一的可导出软件私钥语义。
- 生成：输入名称，生成后保存公钥元数据和私钥材料。
- 导入：支持无 passphrase 的 OpenSSH、PEM、PKCS#8 私钥；加密私钥、格式错误、算法不匹配均在表单内显示具体错误，不弹无关 alert。
- 导出私钥属于敏感操作，使用确认弹窗并明确风险；导出公钥不需要二次确认。

生成和导出的私钥均为无 passphrase 的 canonical 文本格式；生成的私钥从 Keychain 读取后才可导出。导出私钥使用系统分享面板和明确的文件名，不写入日志，也不自动写入剪贴板。

## 数据与安全

- `Host.AuthKind` 只保留 `password` 与 `key`，移除 `keyPassphrase` 和 `agent`。
- `Host.keyUUID` 关联 `SSHKey`；新建/编辑主机保存认证方式与密钥关联。
- 私钥材料只进入 Keychain/CredentialStore，不写 SQLite；SQLite 只保存密钥元数据、公钥、`privateRef` 引用和关联关系。Keychain account 使用 `conn.key.<id>.private`，访问级别为设备解锁后可用且不可迁移。全链路删除 `CredentialStore` 的 host passphrase 读写接口、Keychain passphrase account、`SSHPrivateKeyMaterial.passphrase` 字段及相关 ViewModel 状态；切换认证方式时不再读写或清理任何 passphrase，因为该凭据不再存在。
- 指纹不单独入库：从 SSH 公钥 blob 派生 `SHA256:<base64 无 padding>`，导入和生成时都校验算法前缀、blob 和指纹一致，列表展示摘要，详情展示完整值。
- 删除密钥前展示正在使用它的主机数量；有主机使用时默认阻止删除并提供“先修改主机认证”的入口，避免 `keyUUID = NULL` 但 `authKind = key` 的坏状态。`SSHKeyRepository.delete` 必须在同一个 SQLite write transaction 内重新检查主机关联，并使用 `ON DELETE RESTRICT`（或等价触发器）作为数据库兜底，不能只依赖 UI 的前置计数。确认无引用后，先删除 Keychain 私钥，成功后再删除 SQLite 元数据；Keychain 删除按幂等操作处理。若 SQLite 删除失败，不吞错、不恢复或伪造成功，保留元数据并返回“删除未完成，请重试”；下一次删除会再次执行幂等 Keychain 清理后重试 SQLite 删除。若两步之间 App 崩溃，记录仍可见，用户再次删除即可恢复，不引入隐藏的待删除状态。
- 当前 App 仍在开发阶段，不增加旧认证枚举或 passphrase 的数据库迁移兼容逻辑。

开发阶段的 schema、fixture 和演示数据同步更新为新枚举；旧 `auth_kind` 值不再静默回退到 `.key`，未知 `SSHKey.Kind`（包括 `se_p256`）也不再静默回退到 Ed25519。DEBUG 数据库直接重建，生产代码遇到未知认证或算法值返回数据错误并要求重新创建主机/密钥。

## 技术边界

- 扩展 `SSHKeyGenerator` 和密钥解析层，统一产出算法、SHA-256 指纹、公钥文本、canonical 私钥文本和私钥材料。算法契约为：Ed25519 → `ssh-ed25519` + OpenSSH；RSA 4096 → `ssh-rsa` 公钥且连接签名必须协商 `rsa-sha2-256/512`；ECDSA P-256 → `ecdsa-sha2-nistp256` + SEC1/PKCS#8 兼容格式。
- `AuthMapping` 只接受密码或完整的私钥材料；移除 `SSHPrivateKeyMaterial.passphrase` 解密参数、CredentialStore 的 host passphrase API 和未实现的 agent 分支。若底层引擎无法协商 RSA SHA-2，连接返回明确的 `rsaSha2Unsupported`，不伪装成密码错误。
- `KeyManagerViewModel` 负责列表、生成、导入、删除、导出数据准备；SwiftUI View 只负责呈现和系统分享/复制入口。
- 新建服务器表单通过 `SSHKeyRepository` 读取可选密钥，选择结果写入 `HostDraft.keyUUID`。`authKind = key` 保存前必须存在对应记录且 Keychain 私钥可读；切到 password 清除 `keyUUID`，切到 key 清除密码字段。编辑时预选已有密钥；密钥已删除或 Keychain 不可读时显示字段错误并阻止保存。

## 验证

- 单元测试覆盖三种算法的生成、固定 SHA-256 指纹、公钥前缀、OpenSSH/PEM/PKCS#8 无 passphrase 导入导出往返，以及 mismatch、malformed、unsupported、encrypted key 输入。
- 认证模型测试确认只有密码和密钥两种枚举分支，密钥认证路径绝不读取/保存 passphrase，未知旧枚举不会静默解释为 `.key`。
- Repository/Keychain 测试覆盖缺私钥、删除失败、删除补偿、事务内并发重查，以及主机关联时拒删的不变量。
- UI 测试确认密钥管家新增按钮位于导航栏、空状态居中、主机表单可选择已有密钥、切换认证清理状态、详情页复制/导出入口可见；导出私钥走确认后的系统分享面板。
- 使用当前已启动的 iPhone 17 Pro 模拟器执行 `xcodebuild test -workspace Conn.xcworkspace -scheme Conn -destination 'id=<booted iPhone 17 Pro UDID>' -parallel-testing-enabled NO`，不重启或克隆模拟器；Keychain 访问由内存 CredentialStore 和 KeychainStore 单测覆盖，Secure Enclave 不在本期验证范围。
