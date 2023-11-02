from modulo import modulo
from sympy import randprime
import random
import rsa

k = 256
r = 2**k


def mod_inverse(x, mod):
    r, t = extended_gcd(x, mod)
    if r != 1:
        raise ValueError(f"Cannot invert {x}")
    val = t if t >= 0 else t + mod
    return val % mod


def extended_gcd(x, mod):
    t = 0
    new_t = 1
    r = mod
    new_r = x
    while True:
        if new_r == 0:
            return (r, t)
        quotient = r // new_r
        t, new_t = new_t, t - (quotient * new_t)
        r, new_r = new_r, r - (quotient * new_r)


def n_residue(x, n):
    return (x << k) % n


def reference_mon_pro(A, B, n):
    r_inv = mod_inverse(r, n)
    return (A * B * r_inv) % n


def reference_exp_lr(M, e, n):
    C = M if get_bit(e, k-1) else 1
    for i in range(k-2, -1, -1):
        C = (C * C) % n
        if get_bit(e, i):
            C = (C * M) % n
    return C


def reference_exp_rl(M, e, n):
    C = 1
    P = M
    for i in range(k):
        if get_bit(e, i):
            C = (C * P) % n
        P = (P * P) % n
    return C


def get_bit(A, n):
    return (A >> n) & 1


def mon_pro(A, B, n):
    bn = B + n
    u = 0
    for i in range(k):
        qi = (u & 1) ^ (get_bit(A, i) & (B & 1))
        ai = get_bit(A, i)
        if not qi and not ai:
            u = u
        elif not qi and ai:
            u = u + B
        elif qi and not ai:
            u = u + n
        elif qi and ai:
            u = u + bn
        u = u >> 1
    if u > n:
        u = u - n
    return u


def mon_exp_lr(M, e, n):
    r2_mod = (1 << (2*k)) % n
    M_bar = mon_pro(M, r2_mod, n)
    x_bar = mon_pro(1, r2_mod, n)
    for i in range(k-1, -1, -1):
        x_bar = mon_pro(x_bar, x_bar, n)
        if get_bit(e, i):
            x_bar = mon_pro(M_bar, x_bar, n)
    x = mon_pro(x_bar, 1, n)
    return x


def mon_exp_rl(msg, exponent, modulo):
    r2_mod = (1 << (2*k)) % modulo
    product = mon_pro(msg, r2_mod, modulo)
    result = mon_pro(1, r2_mod, modulo)
    # print(f"product: {product:0{k//4}x}")
    # print(f"result: {result:0{k//4}x}\n")
    for i in range(k):
        if get_bit(exponent, i):
            result = mon_pro(result, product, modulo)
        product = mon_pro(product, product, modulo)
        # print(f"product: {product:0{k//4}x}")
        # print(f"result: {result:0{k//4}x}\n")
    result = mon_pro(result, 1, modulo)
    # print(f"product: {product:0{k//4}x}")
    # print(f"result: {result:0{k//4}x}\n")
    return result


def encode_rsa(msg, e, n):
    return mon_exp_rl(msg, e, n)


def decode_rsa(msg, d, n):
    return mon_exp_rl(msg, d, n)


# Use cases

def monpro_test_cases():
    n_nums = 100
    n = 0xc9e0ecb4e5937f391371c0c1ec8a9190afc28d942ee615b466e86b525e75fb67
    a = [random.randrange(0, n) for _ in range(n_nums)]
    b = [random.randrange(0, n) for _ in range(n_nums)]
    out = [mon_pro(a, b, n) for (a, b) in zip(a, b)]
    with open("monpro_golden_inputs.txt", 'w') as f:
        # Interleave As and Bs
        f.writelines([f"{a:0{k//4}x}\n{b:0{k//4}x}\n" for (a, b) in zip(a, b)])
    with open("monpro_golden_outputs.txt", 'w') as f:
        f.writelines([f"{num:0{k//4}x}\n" for num in out])


def exp_test_cases():
    with open("exp_golden_inputs.txt", 'w') as f_in:
        with open("exp_golden_outputs.txt", 'w') as f_out:
            n_nums = 30
            for i in range(n_nums):
                prime = randprime(3, 1 << 255)
                (_, privkey) = rsa.newkeys(256, exponent=prime)
                e, d, n = privkey.e, privkey.d, privkey.n
                r2_mod = (1 << (2*k)) % n
                num = random.randrange(0, n)
                encoded = encode_rsa(num, e, n)
                decoded = decode_rsa(encoded, d, n)

                f_in.write(f"{n:0{k//4}x}\n")
                f_in.write(f"{r2_mod:0{k//4}x}\n")
                f_in.write(f"{e:0{k//4}x}\n")
                f_in.write(f"{num:0{k//4}x}\n")
                f_out.write(f"{encoded:0{k//4}x}\n")

                f_in.write(f"{n:0{k//4}x}\n")
                f_in.write(f"{r2_mod:0{k//4}x}\n")
                f_in.write(f"{d:0{k//4}x}\n")
                f_in.write(f"{encoded:0{k//4}x}\n")
                f_out.write(f"{decoded:0{k//4}x}\n")

                ref_encoded = modulo(num, n) ** e
                ref_decoded = ref_encoded ** d
                if encoded != ref_encoded.residue:
                    print("Encoding error")
                if decoded != ref_decoded.residue:
                    print("Decoding error")


def test_against_lib():
    (_, privkey) = rsa.newkeys(256)
    e, d, n = privkey.e, privkey.d, privkey.n
    print(f"{e:x}, {d:x}, {n:x}")
    msg = 2378678
    encoded = encode_rsa(msg, e, n)
    decoded = decode_rsa(encoded, d, n)
    print("Msg:", msg)
    print("Encoded monpro:", encoded)
    print("Decoded monpro:", decoded)
    encoded = modulo(msg, n) ** e
    decoded = encoded ** d
    print("Encoded lib:", encoded)
    print("Decoded lib:", decoded)

    n_keys = 100
    n_nums_per_key = 10
    encode_ok = []
    decode_ok = []
    for _ in range(n_keys):
        prime = randprime(3, 1 << 255)
        (_, privkey) = rsa.newkeys(256, exponent=prime)
        e, d, n = privkey.e, privkey.d, privkey.n
        numbers = [random.randrange(0, n) for _ in range(n_nums_per_key)]
        my_encoded = [encode_rsa(num, e, n) for num in numbers]
        ref_encoded = [modulo(num, n) ** e for num in numbers]
        my_decoded = [decode_rsa(num, d, n) for num in my_encoded]
        ref_decoded = [num ** d for num in ref_encoded]
        encode_ok.append(
            all([a == b.residue for (a, b) in zip(my_encoded, ref_encoded)]))
        decode_ok.append(
            all([a == b.residue for (a, b) in zip(my_decoded, ref_decoded)]))
    print("encode ok:", all(encode_ok))
    print("decode ok:", all(decode_ok))


def test_against_conceptual_monpro():
    global mon_pro
    (pubkey, privkey) = rsa.newkeys(256)
    print(f"{privkey.e:x}, {privkey.d:x}, {privkey.n:x}")
    msg = 2378678
    encoded = encode_rsa(msg, privkey.e, privkey.n)
    decoded = decode_rsa(encoded, privkey.d, privkey.n)
    print("Msg:", msg)
    print("Encoded monpro:", encoded)
    print("Decoded monpro:", decoded)
    def mon_pro(a, b, n): return reference_mon_pro(a, b, n, mod_inverse(r, n))
    encoded = encode_rsa(msg, privkey.e, privkey.n)
    decoded = decode_rsa(encoded, privkey.d, privkey.n)
    print("Encoded ref monpro:", encoded)
    print("Decoded ref monpro:", decoded)


def test_lr_x_rl():
    global mon_pro
    (_, privkey) = rsa.newkeys(256)
    e, d, n = privkey.e, privkey.d, privkey.n
    print(f"{e:x}, {d:x}, {n:x}")
    msg = 2378678
    print("Msg:", msg)
    encoded = mon_exp_lr(msg, e, n)
    decoded = mon_exp_lr(encoded, d, n)
    print("Encoded lr:", encoded)
    print("Decoded lr:", decoded)
    encoded = mon_exp_rl(msg, e, n)
    decoded = mon_exp_rl(encoded, d, n)
    print("Encoded rl:", encoded)
    print("Decoded rl:", decoded)
    encoded = reference_exp_rl(msg, e, n)
    decoded = reference_exp_rl(encoded, d, n)
    print("Encoded reference rl:", encoded)
    print("Decoded reference rl:", decoded)


def test_fixed_nums():
    # n = 0xba188f406e72ec94a20216e6a3508be2bd65a2e17fd858fc5c5510af39470f53
    # e = 0x0000000000000000000000000000000000000000000000000000000000010001
    # msg = 0x46d1a878e619501a9a0c63cdacc03f2490816ae5204c5a6f0570789481f1fa87
    n = 0xba188f406e72ec94a20216e6a3508be2bd65a2e17fd858fc5c5510af39470f53
    e = 0x0db9f607089e8d78c1226a5204c5d21a54138967737852a0838719a9056a3cb1
    msg = 0x4fe88f7e62256399d95b16699970a58de3c343ef6a92ab07973b3b151ee0e811
    mon_exp_rl(msg, e, n)

if __name__ == "__main__":
    # test_fixed_nums()
    # test_against_lib()
    # test_against_conceptual_monpro()
    # test_lr_x_rl()
    exp_test_cases()
    # monpro_test_cases()
