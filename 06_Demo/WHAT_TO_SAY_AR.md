# تحضير شرح المشروع قدام الدكتور

**اسم المشروع:** HomeRescue AI.

**فكرة السؤال:** إزاي نرتب مباني Staten Island حسب خطورة مشاكل الصيانة في سنة 2024؟ بنستخدم شكاوى السكان، مخالفات الصيانة، وأوامر الإصلاح HPD.

**Bronze:** بنحمّل أربعة مصادر رسمية من NYC Open Data كما هي كنصوص (مع حفظ المصدر ووقت التحميل) عشان عندنا provenance.

**Silver:** بننظف البيانات ونوحد building_id ونحول dates/numbers، ونسجل الصفوف المرفوضة والمكررة ونحسب reconciliation.

**Gold:** بنبني DimBuilding وDimDate، وثلاث facts للمشاكل والمخالفات وأوامر الإصلاح، وبعدها Mart لكل building/month، وبنعمل feature view وranking.

**ليه ما جمعناش كل الـFacts مباشرة؟** عشان ما يحصلش many-to-many fan-out وتتضاعف الشكاوى أو مبالغ الإصلاح في الحساب.

**ليه بنفرق بين complaint_id وproblem_id؟** الشكوى الواحدة ممكن تحتوي أكثر من مشكلة. فلازم COUNT DISTINCT complaints منفصل عن COUNT problems.

**النتيجة:** ترتيب للمباني وتحديد أماكن فيها مخالفات خطيرة ولم تسجل eligible OMO repair orders.

**جملة مهمة:** Score ده مؤشر وصفي قابل للفهم، مش موديل Machine Learning متدرب، و OMO award مش معناه إن المبلغ اتدفع فعلًا.

افتح `DEMO_QUERIES.sql` في SSMS واضغط Execute لكل قسم عشان تعرض الأرقام الفعلية من قاعدة بياناتك.
