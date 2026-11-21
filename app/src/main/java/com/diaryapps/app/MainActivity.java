package com.diaryapps.app;

import android.app.Activity;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.pdf.PdfDocument;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.print.PrintAttributes;
import android.print.PrintDocumentAdapter;
import android.print.PrintManager;
import android.provider.MediaStore;
import android.util.Base64;
import android.webkit.JavascriptInterface;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStream;

public class MainActivity extends Activity {
    private WebView web;
    private WebView printView; // kept so it is not garbage-collected while printing

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        web = new WebView(this);
        setContentView(web);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setAllowFileAccess(true);
        s.setAllowContentAccess(false);
        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri u = request.getUrl();
                String sc = u.getScheme();
                if ("tel".equals(sc) || "sms".equals(sc) || "mailto".equals(sc)) {
                    try {
                        startActivity(new Intent("tel".equals(sc) ? Intent.ACTION_DIAL : Intent.ACTION_VIEW, u));
                    } catch (Exception ignored) { }
                    return true;
                }
                return false;
            }
        });
        web.addJavascriptInterface(new Bridge(), "Android");
        web.loadUrl("file:///android_asset/index.html");
    }

    /** Native functions callable from the web UI as window.Android.* */
    private class Bridge {
        @JavascriptInterface
        public void share(String text) {
            Intent i = new Intent(Intent.ACTION_SEND);
            i.setType("text/plain");
            i.putExtra(Intent.EXTRA_TEXT, text);
            startActivity(Intent.createChooser(i, "Share"));
        }

        /** Opens the Android print dialog (printers, or "Save as PDF") for an HTML document. */
        @JavascriptInterface
        public void print(final String html, final String title) {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    WebView pv = new WebView(MainActivity.this);
                    pv.setWebViewClient(new WebViewClient() {
                        @Override
                        public void onPageFinished(WebView v, String url) {
                            PrintManager pm = (PrintManager) getSystemService(Context.PRINT_SERVICE);
                            PrintDocumentAdapter adapter = v.createPrintDocumentAdapter(title);
                            pm.print(title, adapter, new PrintAttributes.Builder()
                                    .setMediaSize(PrintAttributes.MediaSize.ISO_A4).build());
                        }
                    });
                    pv.loadDataWithBaseURL(null, html, "text/html", "UTF-8", null);
                    printView = pv;
                }
            });
        }

        /**
         * Saves an invoice picture (base64 PNG drawn by the web UI) as png, jpg or pdf.
         * Returns "ok:<where>" or "err:<reason>".
         */
        @JavascriptInterface
        public String saveFile(String base64Png, String name, String kind) {
            try {
                byte[] png = Base64.decode(base64Png, Base64.DEFAULT);
                Bitmap bmp = BitmapFactory.decodeByteArray(png, 0, png.length);
                byte[] data;
                String mime, fname;
                if ("pdf".equals(kind)) {
                    data = toPdf(bmp);
                    mime = "application/pdf";
                    fname = name + ".pdf";
                } else if ("jpg".equals(kind)) {
                    ByteArrayOutputStream b = new ByteArrayOutputStream();
                    bmp.compress(Bitmap.CompressFormat.JPEG, 92, b);
                    data = b.toByteArray();
                    mime = "image/jpeg";
                    fname = name + ".jpg";
                } else {
                    data = png;
                    mime = "image/png";
                    fname = name + ".png";
                }
                boolean isImage = !"pdf".equals(kind);
                String where;
                if (Build.VERSION.SDK_INT >= 29) {
                    ContentValues cv = new ContentValues();
                    cv.put(MediaStore.MediaColumns.DISPLAY_NAME, fname);
                    cv.put(MediaStore.MediaColumns.MIME_TYPE, mime);
                    String folder = isImage ? Environment.DIRECTORY_PICTURES : Environment.DIRECTORY_DOWNLOADS;
                    cv.put(MediaStore.MediaColumns.RELATIVE_PATH, folder + "/DiaryApps");
                    Uri collection = isImage ? MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                            : MediaStore.Downloads.EXTERNAL_CONTENT_URI;
                    Uri uri = getContentResolver().insert(collection, cv);
                    if (uri == null) return "err:insert";
                    OutputStream os = getContentResolver().openOutputStream(uri);
                    os.write(data);
                    os.close();
                    where = folder + "/DiaryApps/" + fname;
                } else {
                    File dir = getExternalFilesDir(isImage ? Environment.DIRECTORY_PICTURES : Environment.DIRECTORY_DOWNLOADS);
                    File f = new File(dir, fname);
                    FileOutputStream os = new FileOutputStream(f);
                    os.write(data);
                    os.close();
                    where = f.getAbsolutePath();
                }
                return "ok:" + where;
            } catch (Exception e) {
                return "err:" + e.getMessage();
            }
        }
    }

    /** A4 PDF; a tall invoice continues onto extra pages. */
    private byte[] toPdf(Bitmap bmp) throws Exception {
        final int PW = 595, PH = 842, M = 24;
        float sc = (PW - 2f * M) / bmp.getWidth();
        float ph = PH - 2f * M;
        int pages = Math.max(1, (int) Math.ceil(bmp.getHeight() * sc / ph));
        PdfDocument doc = new PdfDocument();
        Paint paint = new Paint(Paint.FILTER_BITMAP_FLAG);
        for (int i = 0; i < pages; i++) {
            PdfDocument.Page page = doc.startPage(new PdfDocument.PageInfo.Builder(PW, PH, i + 1).create());
            Canvas c = page.getCanvas();
            c.drawColor(Color.WHITE);
            c.save();
            c.clipRect(M, M, PW - M, PH - M);
            c.translate(M, M - i * ph);
            c.scale(sc, sc);
            c.drawBitmap(bmp, 0, 0, paint);
            c.restore();
            doc.finishPage(page);
        }
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        doc.writeTo(out);
        doc.close();
        return out.toByteArray();
    }

    @Override
    public void onBackPressed() {
        // Let the web UI close dialogs / sub-screens first.
        web.evaluateJavascript("window.onBack ? window.onBack() : false", value -> {
            if (!"true".equals(value)) exitApp();
        });
    }

    private void exitApp() {
        super.onBackPressed();
    }
}
