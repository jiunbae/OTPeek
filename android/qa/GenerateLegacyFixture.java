import javax.crypto.*;
import javax.crypto.spec.*;
import java.nio.*;
import java.nio.file.*;
import java.security.SecureRandom;
/** Fixture data only; production backup crypto stays in Rust. */
class GenerateLegacyFixture {
 public static void main(String[] args) throws Exception {
  String json="{\"version\":1,\"exportedAt\":\"2024-01-01T12:00:00Z\",\"accounts\":[{\"type\":\"hotp\",\"secret\":\"GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ\",\"accountName\":\"Legacy-fixture\",\"counter\":0}],\"folders\":[]}";
  byte[] salt=new byte[32],nonce=new byte[12];new SecureRandom().nextBytes(salt);new SecureRandom().nextBytes(nonce);
  PBEKeySpec spec=new PBEKeySpec("fixture-legacy".toCharArray(),salt,100000,256);
  byte[] key=SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).getEncoded();
  Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.ENCRYPT_MODE,new SecretKeySpec(key,"AES"),new GCMParameterSpec(128,nonce));
  byte[] enc=cipher.doFinal(json.getBytes(java.nio.charset.StandardCharsets.UTF_8));
  byte[] result=ByteBuffer.allocate(68+enc.length-16).order(ByteOrder.LITTLE_ENDIAN).put("OTPB".getBytes()).putInt(1).put(salt).put(nonce).put(enc,enc.length-16,16).put(enc,0,enc.length-16).array();
  Files.write(Path.of(args[0]),result);java.util.Arrays.fill(key,(byte)0);spec.clearPassword();
 }
}
