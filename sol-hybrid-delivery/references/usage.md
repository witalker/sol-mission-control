# 使用说明

## 推荐设置

父任务选择 GPT-5.6 Sol，推理强度使用 Max。Skill 会自行决定 Direct Sol、Luna 或 Terra；不要在启动提示词里预先指定一定要用哪一个子模型。

## 最简单的启动方式

普通实现任务：

```text
$sol-hybrid-delivery 完成这个任务，效果优先，持续做到本地实现和验证完成。
```

长任务：

```text
$sol-hybrid-delivery 持续完成：<目标>。由 Sol 自主选择 Direct Sol、Luna 或 Terra；最多一波、两个无冲突写代理。子代理失败时由 Sol 在现有授权内自动接管，不要停下来询问模型切换权限。
```

Plan 模式：

```text
$sol-hybrid-delivery 只规划：<目标>。输出路由、写入租约、验收标准和最多两个冻结任务包；不执行、不修改、不启动子代理。
```

## 什么时候适合

- 大量确定性机械修改：通常 Luna。
- 有现成测试约束的局部逻辑、重构或补测：通常 Terra。
- 语义不清、强集成、小改动、线上/设备/部署工作：通常 Direct Sol。
- 一个机械包和一个逻辑包完全独立：可以 Luna + Terra 并行。

如果两个包共享文件、schema、fixture、命令、生成物、缓存、端口或最终验收路径，就不能并行。

## 查看审计

任务结束后运行：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\sol-hybrid-delivery\scripts\audit-session-usage.ps1" `
  -SessionId <父任务ID>,<全部子任务ID>,<可选Direct-Sol基线ID> `
  -MilestoneId <可选里程碑ID>
```

重点查看 `QualityOutcomeCalculated` 和 `DelegationOutcomeCalculated`：任务可以最终 `PASS`，同时委派因为 Sol 接管或消耗更高而是 `LOSS`。这正是新版用来避免“做完了就算协作有效”的机制。

Skill 默认不隐式触发。需要使用时明确写 `$sol-hybrid-delivery`。安装或升级后，如 Skill 列表仍显示旧内容，重启 Codex App。

旧任务的 `SOL_LUNA_AUDIT_V1` 或 `SOL_TERRA_DELIVERY_V1` 标记不会被追溯改写；审计旧任务时继续使用对应旧 Skill 的审计方式。统一版的双轴结论只从新任务的 `SOL_HYBRID_DELIVERY_V1` 标记开始生效。
