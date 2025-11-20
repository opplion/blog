---
title: golang笔记—DTM
date: 2025-11-16 00:12:26
tags: golang
categories: 后端
cover: http://sona-nyl.oss-cn-hangzhou.aliyuncs.com/img/7.webp
---

## 前言
在实际场景中，一个请求可能会伴随多条数据的改动，如果数据都在同一个数据库的话，可以利用数据库本身的 ACID 性质来保证操作的原子性，但是如果数据不在同一个库里呢，或者说对数据的操作不在一台机子上呢。在这种情况下，为保证数据的一致性，我们需要引入一个组件，来帮我们管理分布式事务，这就是DTM干的事情。

## 分布式事务
简单来说，分布式事务的核心在于保证在分布式系统中，对多个数据源（这些数据源可能位于不同节点）的操作仍然满足事务的 ACID 特性。比较常用的模式有很多，有分阶段提交，失败回滚等策略，本质是在 一致性、性能 和 复杂度 之间做取舍。

## DTM是如何工作的
在DTM的架构中，系统分为三种角色RM,TM,AP。RM负责管理全局事务中的本地事务，换句话说，就是被调用的微服务；AP就是需要执行事务的服务，通过DTM客户端向TM提交每个微服务的webhook以及payload然后让TM去执行每个事务；TM就是DTM服务，负责全局事务的管理，每个全局事务都注册到TM，每个事务分支也注册到TM，过了提交阶段全部执行，遇到不行的全部回滚，并将执行状态记录到数据库。
![架构图](http://sona-nyl.oss-cn-hangzhou.aliyuncs.com/img/架构.webp)
## 源码分析 （以saga模式为例）
``` go
	if *isReset {
		dtmsvr.PopulateDB(false)
	}
	_, _ = maxprocs.Set(maxprocs.Logger(logger.Infof))
	registry.WaitStoreUp()
	app := dtmsvr.StartSvr()   
```
在DTM第一次启动时，会连接配置里的数据库地址并执行一个sql脚本，清空数据库的所有表，然后新建事务的状态表，确定连接没有问题后，会启动一个gin服务器，等待客户端的提交

``` go
saga := dtmcli.NewSaga(DtmServer, shortuuid.New()).
  // 添加一个TransOut的子事务，正向操作为url: qsBusi+"/TransOut"， 逆向操作为url: qsBusi+"/TransOutCompensate"
  Add(qsBusi+"/TransOut", qsBusi+"/TransOutCompensate", req).
  // 添加一个TransIn的子事务，正向操作为url: qsBusi+"/TransIn"， 逆向操作为url: qsBusi+"/TransInCompensate"
  Add(qsBusi+"/TransIn", qsBusi+"/TransInCompensate", req)
// 提交saga事务，dtm会完成所有的子事务/回滚所有的子事务
err := saga.Submit()
```
在AP里的客户端，需要手动生成一个uuid作为全局标识，然后创建一个待提交的全局事务对象，通过add方法向这个对象里添加正相操作和反向操作的RM地址及负载，最后向TM提交所有事务

``` go
func svcSubmit(t *TransGlobal) interface{} {
	t.Status = dtmcli.StatusSubmitted
	branches, err := t.saveNew()
	if err == storage.ErrUniqueConflict {
		dbt := GetTransGlobal(t.Gid)
		if dbt.Status == dtmcli.StatusPrepared {
			dbt.changeStatus(t.Status)
			branches = GetStore().FindBranches(t.Gid)
		} 
	} 
	return t.Process(branches)
}
```

提交过程是整个链路的核心大概分为两步：1.事务验证和保存，2.事务的执行
1. 为了防止重复提交，DTM选择将存事务和获取事务的过程拆分开来，这样能保证因为网络问题造成的uuid重复问题，获取到的事务的status如果不是已完成，才会执行后续过程
2. 这里的代码非常长，就只讲一下简单的思路，这步会维护两个函数和一个状态，一个函数控制正滚，一个回滚。如果正向函数有一个报err了，那就把状态改成aborting然后根据当前索引执行回滚函数链，最后改成fail，反之如果都ok则把状态改成Succeed。

这样一个简单的链路就打通了

## 总结
DTM的源码非常多，本文只是介绍其中的一小部分，其中除了事务的处理，其他的编码细节包括：gin的高级用法，代理函数，sql脚本执行，日志的统一监控等等也是很值得学习的