# Backspace — Screen Specifications Draft

## Purpose

This document defines the MVP screen-level requirements for the Backspace internal Arabic RTL web app.

It complements:

- `projects/backspace/README.md`
- `projects/backspace/PRD.md`
- `projects/backspace/API_CONTRACTS.md`
- `projects/backspace/TECHNICAL_DESIGN.md`

Backspace is internal-only. No visitor/customer-facing screens are included in MVP.

---

## Global UI Rules

- All screens are Arabic RTL.
- All pages except `/login` require staff authentication.
- All actions must be permission-aware server-side and UI-side.
- Validation messages are Arabic.
- Empty states must explain what the staff user should do next.
- Destructive actions use confirmation dialogs.
- Tables should support search/filter where specified.

---

## Common App Shell

### Applies to

All authenticated pages.

### Layout

- Right-to-left page direction.
- Sidebar navigation.
- Header with current staff user and role.
- Location name from `LocationSettings`.
- Logout action.

### Navigation Items

- لوحة التحكم
- المساحات
- العملاء
- الزيارات
- الاشتراكات
- الحجوزات
- الفواتير
- التقارير
- الإعدادات

### Role Visibility

| Nav item | Owner | Manager | Staff |
|---|---:|---:|---:|
| Dashboard | ✅ | ✅ | ✅ |
| Spaces | ✅ | ✅ | ✅ read-only for Staff |
| Customers | ✅ | ✅ | ✅ |
| Visits | ✅ | ✅ | ✅ |
| Subscriptions | ✅ | ✅ | ✅ read-only for Staff |
| Bookings | ✅ | ✅ | ✅ |
| Invoices | ✅ | ✅ | ✅ |
| Reports | ✅ | ✅ | Limited |
| Settings | ✅ | Limited/hidden | Hidden |

---

## `/login`

### Purpose

Allow internal staff users to sign in.

### Fields

- البريد الإلكتروني
- كلمة المرور

### Actions

- تسجيل الدخول

### States

- Loading while authenticating.
- Invalid credentials.
- Disabled account.
- Generic system error.

### Arabic messages

- “بيانات الدخول غير صحيحة”
- “هذا الحساب غير مفعل”
- “حدث خطأ، حاول مرة أخرى”

### Acceptance Criteria

- Root layout is RTL.
- Successful login redirects to `/dashboard`.
- No customer signup/login link exists.

---

## `/dashboard`

### Purpose

Show daily operational summary.

### Owner/Manager widgets

- زيارات مفتوحة الآن
- زيارات اليوم
- حجوزات اليوم والقادمة
- إشغال حالي
- اشتراكات قرب الانتهاء
- فواتير غير مدفوعة
- إيراد اليوم
- إيراد الشهر

### Staff widgets

- زيارات مفتوحة الآن
- زيارات اليوم
- حجوزات اليوم والقادمة
- اشتراكات قرب الانتهاء

### Hidden for Staff

- Full revenue totals.
- Unpaid invoice financial summary.

### Empty states

- “لا توجد زيارات مفتوحة الآن”
- “لا توجد حجوزات قادمة اليوم”

---

## `/spaces`

### Purpose

Manage workspace spaces and hourly rates.

### Table columns

- الاسم
- النوع
- السعة
- سعر الساعة
- الحالة
- آخر تحديث
- إجراءات

### Actions

Owner/Manager:

- إضافة مساحة
- تعديل مساحة
- تعطيل مساحة
- إعادة تفعيل مساحة

Staff:

- عرض فقط

### Form fields

- اسم المساحة
- النوع
- السعة
- سعر الساعة
- ملاحظات

### Validation messages

- “اسم المساحة مطلوب”
- “السعة يجب أن تكون أكبر من صفر”
- “سعر الساعة غير صحيح”

---

## `/customers`

### Purpose

Search, create, and manage internal customer records.

### Filters

- بحث بالاسم أو الهاتف
- نوع العميل: زائر / مشترك / شركة
- الحالة: نشط / مؤرشف

### Table columns

- الاسم
- الهاتف
- النوع
- الحالة
- آخر تحديث
- إجراءات

### Actions

- إضافة عميل
- تعديل عميل
- عرض التفاصيل
- أرشفة — Owner/Manager only

### Form fields

- الاسم
- الهاتف
- البريد الإلكتروني اختياري
- النوع
- ملاحظات

### Important boundary

Do not show customer login credentials, password fields, or portal links.

---

## `/customers/:id`

### Purpose

Show one customer’s full internal profile.

### Sections

- البيانات الأساسية
- الزيارات
- الاشتراكات
- الحجوزات
- الفواتير والمدفوعات
- الملاحظات

### Actions

- تعديل بيانات العميل
- بدء زيارة جديدة
- إضافة اشتراك — Owner/Manager
- إنشاء حجز
- إنشاء فاتورة

### Empty states

- “لا توجد زيارات لهذا العميل”
- “لا توجد اشتراكات لهذا العميل”
- “لا توجد فواتير لهذا العميل”

---

## `/visits`

### Purpose

Run daily hourly visits.

### Filters

- التاريخ
- الحالة: مفتوحة / مغلقة / ملغاة
- العميل
- المساحة

### Table columns

- العميل
- المساحة
- وقت الدخول
- وقت الخروج
- المدة
- الإجمالي
- الحالة
- إجراءات

### Actions

- بدء زيارة
- إنهاء زيارة
- عرض التفاصيل
- تعديل — Owner/Manager
- إلغاء — Owner/Manager

---

## `/visits/new`

### Purpose

Create a check-in.

### Fields

- العميل
- المساحة
- وقت الدخول
- ملاحظات

### Defaults

- وقت الدخول = الآن.

### Validation

- “يجب اختيار العميل”
- “يجب اختيار المساحة”
- “هذه المساحة غير مفعلة”
- “هذا العميل مؤرشف”

---

## `/visits/:id`

### Purpose

Show visit details and billing calculation.

### Shows

- العميل
- المساحة
- وقت الدخول
- وقت الخروج
- المدة بالدقائق
- مدة المحاسبة
- سعر الساعة المستخدم
- الإجمالي
- الحالة
- الملاحظات
- سجل التعديلات إن وجد

### Actions

- إنهاء الزيارة إذا مفتوحة
- إنشاء فاتورة إذا مغلقة ولم تصدر فاتورة
- تعديل/إلغاء — Owner/Manager only

---

## `/subscriptions`

### Purpose

Manage subscription plans and customer subscriptions.

### Tabs

- خطط الاشتراك
- اشتراكات العملاء

### Plan columns

- الاسم
- النوع
- المدة بالأيام
- السعر
- الحالة
- إجراءات

### Customer subscription columns

- العميل
- الخطة
- تاريخ البداية
- تاريخ النهاية
- الحالة
- السعر وقت الاشتراك
- إجراءات

### Actions

Owner/Manager:

- إضافة خطة
- تعديل خطة
- تعطيل خطة
- إضافة اشتراك لعميل
- إلغاء اشتراك

Staff:

- عرض فقط

---

## `/bookings`

### Purpose

Manage internal staff-created bookings.

### Filters

- التاريخ
- المساحة
- العميل
- الحالة

### Table columns

- العميل
- المساحة
- البداية
- النهاية
- الحالة
- ملاحظات
- إجراءات

### Actions

- إنشاء حجز
- تعديل حجز
- إلغاء حجز
- فحص التوفر

### Conflict UI

If conflict exists, show:

- “هذه المساحة محجوزة في هذا الوقت”
- Existing conflict time range.

---

## `/invoices`

### Purpose

Manage invoices.

### Filters

- الحالة
- العميل
- نوع المصدر
- من تاريخ / إلى تاريخ

### Table columns

- رقم الفاتورة
- العميل
- نوع العملية
- الإجمالي
- المدفوع
- المتبقي
- الحالة
- تاريخ الإصدار
- إجراءات

### Actions

- إنشاء فاتورة
- عرض الفاتورة
- تسجيل دفع
- إلغاء فاتورة — Owner/Manager only

---

## `/invoices/:id`

### Purpose

Show invoice details and payments.

### Sections

- بيانات الفاتورة
- بيانات العميل
- مصدر الفاتورة
- المدفوعات
- المتبقي

### Actions

- تسجيل دفع
- إلغاء فاتورة — Owner/Manager

### Rules

- Cancelled invoices cannot accept payments.
- Paid invoices should show completion state clearly.

---

## `/reports`

### Purpose

Show basic operational and financial reports.

### Tabs

- تقرير الزيارات
- تقرير المدفوعات — Owner/Manager only
- تقرير الاشتراكات
- تقرير الحجوزات

### Common filters

- من تاريخ
- إلى تاريخ
- العميل
- المساحة
- الحالة

### Staff limitations

- Staff cannot access payment report.
- Staff cannot see full revenue totals.

---

## `/settings/location`

### Purpose

Owner configures single-location branding and invoice settings.

### Fields

- اسم المكان
- الشعار
- العنوان
- الهاتف
- بادئة الفاتورة
- الرقم الضريبي
- العملة

### Permissions

- Owner only can update.
- Manager/Staff cannot update.

---

## `/settings/staff`

### Purpose

Owner manages internal staff users.

### Fields/actions

- إضافة موظف
- تعديل الاسم والدور
- تعطيل حساب
- إعادة تفعيل حساب

### Rules

- Password reset flow should avoid exposing raw passwords.
- Disabled users cannot log in because `StaffUser.isActive = false`.

---

## Empty State Copy

Use Arabic empty states consistently:

- “لا توجد بيانات بعد”
- “ابدأ بإضافة أول عنصر”
- “لا توجد نتائج مطابقة للبحث”
- “ليس لديك صلاحية لتنفيذ هذا الإجراء”

---

## Screen QA Checklist

- [ ] All screens are Arabic RTL.
- [ ] All protected pages require authentication.
- [ ] Staff cannot see restricted financial widgets.
- [ ] Owner-only settings are not visible/actionable for Staff.
- [ ] Customers have no login UI.
- [ ] Validation messages are Arabic.
- [ ] Destructive actions require confirmation.
- [ ] Empty states are clear.
