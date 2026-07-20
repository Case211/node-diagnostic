/*
 * nd-shaper.bpf.c — per-IP полосовой шейпер для ноды (eBPF + EDT).
 *
 * Портировано из DonMatteoVPN/Reshala-Remnawave-Bedolaga (MIT), логика
 * сохранена: каждый клиентский IP получает независимый лимит DL/UL под
 * правилом порта; whitelist обходит шейпинг; опц. dynamic-режим со штрафом
 * абузеру. Управляется node-diagnostic.sh (модуль shape.sh + shape_ctrl.py).
 *
 * Карты:
 *   port_rule_map  : port(u32)  → rule_id(u32)
 *   config_map     : rule_id     → struct rule_config (array)
 *   whitelist_map  : ip          → u8
 *   user_state_map_down/up : {ip[4], rule_id} → struct user_state
 *
 * Направления: down = EGRESS главного iface (EDT через skb->tstamp),
 *              up   = INGRESS (token-bucket drop → TCP снижает окно).
 */

#include <linux/bpf.h>
#include <linux/pkt_cls.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <linux/in.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#define MAX_PORTS  32
#define MAX_RULES  32

struct rule_config {
    __u32 mode;                    /* 0=off, 1=static, 2=dynamic, 3=aggregate */
    __u32 num_ports;
    __u32 ports[MAX_PORTS];
    __u64 down_rate_bps;
    __u64 up_rate_bps;
    __u64 penalty_rate_bps;
    __u64 burst_bytes_limit;
    __u64 window_time_ns;
    __u64 penalty_time_ns;
};

struct user_rule_key {
    __u32 addr[4];
    __u32 rule_id;
    __u32 _pad;
};

struct ip_key {
    __u32 addr[4];
};

struct user_state {
    __u64 bytes_in_window;
    __u64 window_start_time;
    __u64 penalty_end_time;
    __u64 last_departure_time;
    __u64 total_bytes;
    __u32 is_penalized;
    __u32 _pad;
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key,   __u32);
    __type(value, __u32);
} port_rule_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, MAX_RULES);
    __type(key,   __u32);
    __type(value, struct rule_config);
} config_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key,   struct ip_key);
    __type(value, __u8);
} whitelist_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key,   struct user_rule_key);
    __type(value, struct user_state);
} user_state_map_down SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key,   struct user_rule_key);
    __type(value, struct user_state);
} user_state_map_up SEC(".maps");

static __always_inline int process_packet(
    struct __sk_buff *skb, __u32 direction, void *user_map)
{
    void *data     = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end) return TC_ACT_OK;

    struct user_rule_key user_key = {0};
    __u16 sport = 0, dport = 0;
    __u8  proto = 0;
    void *trans_hdr = (void *)0;

    if (eth->h_proto == bpf_htons(ETH_P_IP)) {
        struct iphdr *ip = (struct iphdr *)(eth + 1);
        if ((void *)(ip + 1) > data_end) return TC_ACT_OK;

        if (direction == 0) user_key.addr[0] = ip->daddr;
        else                user_key.addr[0] = ip->saddr;

        proto    = ip->protocol;
        trans_hdr = (void *)ip + (ip->ihl * 4);

    } else if (eth->h_proto == bpf_htons(ETH_P_IPV6)) {
        struct ipv6hdr *ipv6 = (struct ipv6hdr *)(eth + 1);
        if ((void *)(ipv6 + 1) > data_end) return TC_ACT_OK;

        if (direction == 0) __builtin_memcpy(user_key.addr, ipv6->daddr.in6_u.u6_addr32, 16);
        else                __builtin_memcpy(user_key.addr, ipv6->saddr.in6_u.u6_addr32, 16);

        proto    = ipv6->nexthdr;
        trans_hdr = (void *)(ipv6 + 1);
    } else {
        return TC_ACT_OK;
    }

    struct ip_key w_key = {0};
    w_key.addr[0] = user_key.addr[0];
    w_key.addr[1] = user_key.addr[1];
    w_key.addr[2] = user_key.addr[2];
    w_key.addr[3] = user_key.addr[3];

    if (bpf_map_lookup_elem(&whitelist_map, &w_key)) {
        return TC_ACT_OK;
    }

    if (proto == IPPROTO_TCP) {
        struct tcphdr *tcp = (struct tcphdr *)trans_hdr;
        if ((void *)(tcp + 1) <= data_end) {
            sport = bpf_ntohs(tcp->source);
            dport = bpf_ntohs(tcp->dest);
        }
    } else if (proto == IPPROTO_UDP) {
        struct udphdr *udp = (struct udphdr *)trans_hdr;
        if ((void *)(udp + 1) <= data_end) {
            sport = bpf_ntohs(udp->source);
            dport = bpf_ntohs(udp->dest);
        }
    }

    __u32 *rule_id_p = (void *)0;
    __u32  s32 = sport, d32 = dport;

    if (s32 > 0) rule_id_p = bpf_map_lookup_elem(&port_rule_map, &s32);
    if (!rule_id_p && d32 > 0) rule_id_p = bpf_map_lookup_elem(&port_rule_map, &d32);

    /* Fallback для правила «все порты» (порт 0) */
    if (!rule_id_p) {
        __u32 zero = 0;
        rule_id_p = bpf_map_lookup_elem(&port_rule_map, &zero);
    }

    if (!rule_id_p) return TC_ACT_OK;

    __u32 rule_id = *rule_id_p;
    if (rule_id >= MAX_RULES) return TC_ACT_OK;

    struct rule_config *conf = bpf_map_lookup_elem(&config_map, &rule_id);
    if (!conf || conf->mode == 0) return TC_ACT_OK;

    user_key.rule_id = rule_id;
    if (conf->mode == 3) {
        user_key.addr[0] = 0;
        user_key.addr[1] = 0;
        user_key.addr[2] = 0;
        user_key.addr[3] = 0;
    }

    struct user_state *state = bpf_map_lookup_elem(user_map, &user_key);
    __u64 now        = bpf_ktime_get_ns();
    __u32 packet_len = skb->len;

    if (!state) {
        struct user_state ns = {
            .window_start_time  = now,
            .last_departure_time = now,
            .total_bytes        = packet_len,
        };
        bpf_map_update_elem(user_map, &user_key, &ns, BPF_ANY);
        return TC_ACT_OK;
    }

    if (conf->mode == 3) {
        state->total_bytes += packet_len;
    } else {
        __sync_fetch_and_add(&state->total_bytes, packet_len);
    }

    if (conf->mode == 2) {
        if (state->is_penalized && now > state->penalty_end_time) {
            state->is_penalized    = 0;
            state->window_start_time = now;
            state->bytes_in_window   = 0;
        }
        if (!state->is_penalized) {
            if (now - state->window_start_time > conf->window_time_ns) {
                state->window_start_time = now;
                state->bytes_in_window   = 0;
            }
            state->bytes_in_window += packet_len;
            if (state->bytes_in_window > conf->burst_bytes_limit) {
                state->is_penalized   = 1;
                state->penalty_end_time = now + conf->penalty_time_ns;
            }
        }
    }

    __u64 rate = (direction == 0) ? conf->down_rate_bps : conf->up_rate_bps;
    if (conf->mode == 2 && state->is_penalized) rate = conf->penalty_rate_bps;
    if (rate == 0) return TC_ACT_SHOT; /* rate 0 = полный блок */

    if (direction == 0) {
        /* Download: EDT — раскладываем отправку во времени через skb->tstamp */
        __u64 delay_ns       = ((__u64)packet_len * 1000000000ULL) / rate;
        __u64 departure_time = state->last_departure_time;
        if (now > departure_time) departure_time = now;
        departure_time += delay_ns;

        if (departure_time - now > 2000000000ULL) return TC_ACT_SHOT; /* >2с вперёд → drop */

        state->last_departure_time = departure_time;
        skb->tstamp = departure_time;
    } else {
        /* Upload: token-bucket drop (EDT недоступен на ingress) */
        __u64 delay_ns       = ((__u64)packet_len * 1000000000ULL) / rate;
        __u64 departure_time = state->last_departure_time;
        if (now > departure_time) departure_time = now;

        /* 200мс буфер: если бакет уходит >200мс вперёд — дропаем (TCP сузит окно) */
        if (departure_time - now > 200000000ULL) {
            return TC_ACT_SHOT;
        }

        state->last_departure_time = departure_time + delay_ns;
    }

    return TC_ACT_OK;
}

SEC("classifier/down")
int nd_shape_down(struct __sk_buff *skb) {
    return process_packet(skb, 0, &user_state_map_down);
}

SEC("classifier/up")
int nd_shape_up(struct __sk_buff *skb) {
    return process_packet(skb, 1, &user_state_map_up);
}

char _license[] SEC("license") = "GPL";
