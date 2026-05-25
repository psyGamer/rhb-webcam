import base64
import ecdsa


if __name__ == "__main__":
    pk = ecdsa.SigningKey.generate(curve=ecdsa.NIST256p)
    vk = pk.get_verifying_key()

    print("Public:", base64.urlsafe_b64encode(vk.to_string()).strip(b"=").decode('utf-8'))
    print("Private:", base64.urlsafe_b64encode(pk.to_string()).strip(b"=").decode('utf-8'))