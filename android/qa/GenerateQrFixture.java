import com.google.zxing.BarcodeFormat;
import com.google.zxing.qrcode.QRCodeWriter;
import java.awt.image.BufferedImage;
import javax.imageio.ImageIO;
import java.io.File;
public class GenerateQrFixture {
    public static void main(String[] args) throws Exception {
        var qr = new QRCodeWriter().encode("otpauth://hotp/Camera-fixture?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&counter=0", BarcodeFormat.QR_CODE, 400, 400);
        var image = new BufferedImage(1080, 1080, BufferedImage.TYPE_INT_RGB);
        for (int y=0;y<1080;y++) for(int x=0;x<1080;x++) image.setRGB(x,y,0xffffff);
        for (int y=0;y<400;y++) for(int x=0;x<400;x++) image.setRGB(x+110,y+340,qr.get(x,y)?0:0xffffff);
        ImageIO.write(image,"png",new File(args[0]));
    }
}
