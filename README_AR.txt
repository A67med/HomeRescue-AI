HomeRescue AI - Fix for SQL error 207 in silver.batch_reconciliation
================================================================
الخطأ: تقرير Silver بيستخدم أسماء أعمدة غير الموجودة في SQL.
التصحيح: silver_table, accepted_rows, rejected_rows, duplicate_rows_removed.

طريقة التنفيذ:
1) اقفل شاشة الخطأ.
2) انسخ الملفين 03_FIX_AND_FINISH.bat و generate_live_reports_FIXED.py
   إلى نفس فولدر المشروع الرئيسي الذي فيه 01_RUN_PROJECT.bat.
3) افتح 03_FIX_AND_FINISH.bat بدبل كليك.
4) لا تحتاج إعادة تشغيل 01_RUN_PROJECT.bat الآن؛ البرنامج سيكمل التقارير والنسخ الاحتياطي فقط.
5) بعد النجاح، افتح 03_Bronze و04_Silver و05_Gold للتحقق من وجود PDF جديد.
6) افتح 07_Database_Backup وتأكد من وجود ملف .bak؛ لو مش موجود اعمله من SSMS.

لو رسالة تقول validation file missing، لا تعتبر المشروع مكتملًا.
ابعت رسالة الخطأ أو الملف RUN_LOG.txt بعد التشغيل.

Note: This patch fixes the reporting script. It does not change database tables or data.
