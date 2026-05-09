#!/bin/bash

# 确保在内核源码根目录运行
if [ ! -f "net/ipv4/tcp.c" ]; then
    echo "❌ 找不到 net/ipv4/tcp.c，请确保你在内核源码根目录下运行此脚本！"
    exit 1
fi

TCP_C="net/ipv4/tcp.c"

echo "🧹 1. 正在清理可能导致干扰的旧残骸..."
sed -i '/--- 新增: TCP Brutal 专属/,/-------------------------------------------/d' "$TCP_C"

echo "💉 2. 开始注入头部结构体..."
awk '
/#include <net\/tcp\.h>/ && !patched {
    print $0
    print ""
    print "// --- 新增: TCP Brutal 专属宏 ---"
    print "#ifndef TCP_BRUTAL_PARAMS"
    print "#define TCP_BRUTAL_PARAMS 23301"
    print "#endif"
    print "struct tcp_brutal_params {"
    print "    u64 rate;"
    print "    u32 cwnd_gain;"
    print "} __attribute__((packed));"
    print "// -------------------------------------------"
    patched=1
    next
}
{print}
' "$TCP_C" > "${TCP_C}.tmp" && mv "${TCP_C}.tmp" "$TCP_C"

echo "💉 3. 开始精准注入 setsockopt 逻辑..."
awk '
/case TCP_NODELAY:/ && !patched {
    print "	case TCP_BRUTAL_PARAMS: { // --- 新增: TCP Brutal 专属处理分支 ---"
    print "		struct tcp_brutal_params params;"
    print "		struct inet_connection_sock *icsk = inet_csk(sk);"
    print "		void *ca = inet_csk_ca(sk);"
    print "		if (optlen < sizeof(params)) {"
    print "			err = -EINVAL;"
    print "			break;"
    print "		}"
    print "		if (copy_from_sockptr(&params, optval, sizeof(params))) {"
    print "			err = -EFAULT;"
    print "			break;"
    print "		}"
    print "		if (!icsk->icsk_ca_ops || strcmp(icsk->icsk_ca_ops->name, \"brutal\") != 0) {"
    print "			err = -EOPNOTSUPP;"
    print "			break;"
    print "		}"
    print "		*(u64 *)ca = params.rate;"
    print "		*(u32 *)((char *)ca + 8) = params.cwnd_gain;"
    print "		cmpxchg(&sk->sk_pacing_status, SK_PACING_NONE, SK_PACING_NEEDED);"
    print "		sk->sk_max_pacing_rate = params.rate;"
    print "		sk->sk_pacing_rate = params.rate;"
    print "		err = 0;"
    print "		break;"
    print "	} // -------------------------------------------"
    print $0
    patched=1
    next
}
{print}
' "$TCP_C" > "${TCP_C}.tmp" && mv "${TCP_C}.tmp" "$TCP_C"

echo "🔍 4. 正在进行注入结果的致命校验..."

# 校验 1：结构体是否成功注入
if ! grep -q "struct tcp_brutal_params {" "$TCP_C"; then
    echo -e "\n❌ [FATAL ERROR] 结构体 tcp_brutal_params 未能成功注入！"
    echo "请检查 tcp.c 头部的 include 声明是否发生了变化。"
    exit 1
fi

# 校验 2：控制分支是否成功注入
if ! grep -q "case TCP_BRUTAL_PARAMS:" "$TCP_C"; then
    echo -e "\n❌ [FATAL ERROR] TCP_BRUTAL_PARAMS 控制分支未能成功注入！"
    echo "请检查 do_tcp_setsockopt 函数中是否还存在 'case TCP_NODELAY:'。"
    exit 1
fi

echo -e "\n✅ 校验通过！TCP Brutal 核心路由补丁已完美植入！"
exit 0