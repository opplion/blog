---
title: 存储引擎篇 LSM Tree
date: 2026-07-07 20:46:38
tags: 数据结构与算法
categories: 计算机基础
cover: https://sona-nyl.oss-cn-hangzhou.aliyuncs.com/img/11.webp
---

## 背景
在 LSM Tree 之前，很多磁盘存储结构使用的是 B+ 树。
B+ 树的优势是读性能稳定，尤其适合范围查询。但它的问题也很明显：写入时需要在磁盘上的树结构中找到对应位置，然后原地修改 page。如果发生页分裂、页合并，最坏情况下可能带来多次随机磁盘 IO。
在一些高写入场景里，比如日志采集、时序数据、消息索引、KV 存储等，写入吞吐往往比单次读取延迟更重要。频繁随机写磁盘会成为系统瓶颈。
于是 LSM Tree 被设计出来。它的核心目标是：
把随机写变成顺序写

## 概要
LSM Tree 的核心思想是：放弃 B+ 树那种频繁原地更新磁盘页的方式，把写入先追加到 WAL，再写入内存中，随后由后台线程批量落到磁盘。
这样一次写请求的关键路径通常只有：
顺序写 WAL + 写内存
不会因为每次更新都随机修改磁盘页，所以写入吞吐很高。
但代价是读路径会变复杂。因为同一个 key 的不同版本可能同时存在于多个地方。查询时需要按照从新到旧的顺序查找，并通过版本号判断最新版本

## 架构图
![架构图](http://sona-nyl.oss-cn-hangzhou.aliyuncs.com/img/lsm.webp)

## 实现原理
lsm 为了实现追加写获得极致的写性能，同时带来了两个问题，一个是读的逻辑会非常复杂，一个是旧版本数据无法被优雅的删除，其他的所有设计大部分是为了解决这两个问题。让我们一步步看 lsm，是怎么把读和存储的成本降下来的。

### 内存表维护有序
MemTable 是 LSM Tree 的内存写入表。在lsm tree的官方论文里，并没有规定具体要怎么实现，但由于sstable的有序性，我们希望内存表也是一种有序的数据结构。业内常用跳表来实现

跳表的好处是实现相对简单，同时可以保持 key 有序。写入时先在每一层找到前驱节点，再把新节点插入进去。查询时也是从高层一路向右、向下查找，平均复杂度是 `O(log n)`。

MemTable 中保存的不只是 key/value，还包含一个全局递增的 sequence：

```text
key -> { sequence, type, value }
```

sequence 表示版本新旧。同一个 key 在不同地方可能有多个版本，后续读取和合并时，就靠 sequence 判断哪条记录是最新的。

当 active MemTable 的大小超过阈值后，它会被冻结成 immutable MemTable，然后创建一个新的 active MemTable 继续承接写入：

```text
active MemTable
    ↓ freeze
immutable MemTable
    ↓ 后台 flush
SSTable
```

这样前台写入不需要一直等待磁盘落盘，只要写完 WAL 和新的 MemTable，就可以继续返回。
**Q: 为什么用跳表而不用红黑树？**
> 📌红黑树插入/删除可能触发旋转和变色，影响父节点、祖父节点甚至更高层节点，并发时通常要加较粗的锁可能要锁整棵树，而跳表插入/删除只需要修改目标位置附近几层前驱节点的 next 指针。一次只要加锁几个节点。
### SSTable 磁盘索引构建
冻结后的 MemTable 会由 FlushWorker 写成 SSTable。

SSTable 的特点是不可变、有序。因为 MemTable 本身就是有序的，所以 flush 时可以直接按 key 顺序遍历，然后顺序写入磁盘。

查询某个 key 时，不需要从文件开头一直扫。它会先看 SSTable 的 `MinKey`、`MaxKey`，如果目标 key 不在范围内，直接跳过这个文件。如果在范围内，再通过稀疏索引找到一个接近的位置，从那里开始顺序扫描。稀疏的程度根据数据量决定，既要保证加载到内存时不会太大，也保证顺序io时不会找太久

读 SSTable 元数据时，只需要从文件尾部读 footer length 和 magic，就能定位 footer，再找到 index 和数据范围。

### 读路径从新到旧查找
LSM 的读路径复杂，是因为同一个 key 可能同时存在于多个地方：

```text
active MemTable
immutable MemTable
L0 SSTable
L1 SSTable
L2 SSTable
...
```

所以 `Get` 的顺序必须从新到旧：

```text
先查 active MemTable
再查 immutable MemTable
再查 L0
最后查更高层
```

L0 比较特殊。L0 文件是 MemTable 直接 flush 出来的，不同 L0 文件之间的 key 范围可能重叠。所以查 L0 时，要按照文件生成顺序从新到旧查。

L1 之后经过 compaction 整理，同一层内的 SSTable key range 通常不重叠。因此查更高层时，可以根据 key 范围快速定位可能包含目标 key 的文件。

如果查到的最新记录是删除标记，就返回不存在。

### LSM Tree 为什么要分层
MemTable 每次 flush 都会生成一个新的 SSTable。如果所有 SSTable 都堆在一起，读一个 key 时就可能要查很多文件，读放大会越来越严重。

所以 LSM Tree 会把 SSTable 分成多层：

```text
L0 -> L1 -> L2 -> L3 ...
```

L0 是最特殊的一层。它直接接收 MemTable flush 出来的文件，所以不同 L0 文件之间的 key 范围可能重叠。比如一个文件范围是 `a~m`，另一个文件也可能是 `c~z`。因此查询 L0 时，不能只根据范围定位一个文件，而是要从新的文件往旧的文件查。

L1 以及更高层，是经过 compaction 整理后的结果。同一层里的 SSTable 通常按照 key range 排列，并且尽量不重叠：

```text
L1: [a, f] [g, m] [n, z]
```

这样查询某个 key 时，就可以根据 key range 快速定位到可能包含它的文件，而不是把整层都扫一遍。

层级还有一个特点：越往下，容量越大。每层成倍增长。这样新数据先停留在上层，旧数据随着 compaction 慢慢下沉到更大的层级。

分层本质上是在平衡两个成本：

```text
上层文件少而新，方便写入快速落盘
下层文件大而稳，方便读取减少查找范围
```

所以 LSM Tree 的分层不是为了把文件简单分类，而是为了控制读放大、写放大和空间放大之间的关系。

### tombstone 解决删除问题
LSM 不能像 B+ 树那样直接去磁盘 page 上删除一条记录，因为 SSTable 是不可变文件。

所以删除操作不是物理删除，而是写入一条特殊记录：

```text
{ key, type: delete, sequence }
```

这条记录叫 tombstone。

读的时候，如果某个 key 的最新版本是 tombstone，就说明这个 key 已经被删除，直接返回 not found。旧版本即使还躺在更老的 SSTable 里，也不能再被读出来。

真正清理旧版本和 tombstone，要等后面的 compaction。

### 大数据合并降级
追加写会不断产生新的 SSTable。如果不合并，读的时候就要查越来越多文件，旧版本数据也会一直占用空间。

Compaction 的作用就是把多个有序文件重新归并成新的有序文件：

```text
多个 SSTable
    ↓
多路归并
    ↓
相同 key 只保留最大 sequence
    ↓
写入下一层 SSTable
    ↓
删除旧 SSTable
```

这个过程本质上就是归并排序。每个 SSTable 内部已经按 key 有序，所以可以用最小堆做多路归并。遇到相同 key 时，比较 sequence，只保留最新版本。

简化版 leveled compaction：

1. L0 文件数量超过阈值后，触发 L0 到 L1 的合并。
2. 合并时找出下一层 key range 有重叠的 SSTable。
3. 把这些文件一起归并，生成新的 SSTable。
4. 删除旧 SSTable 文件。

更高层则根据层级大小触发合并。越老、越稳定的数据会逐渐下沉到更高层，这就是所谓的冷数据下沉。

## 项目地址
如果有什么改进的建议的话，欢迎留 issue
[仓库代码](https://github.com/opplion/kv-storge-engine)
