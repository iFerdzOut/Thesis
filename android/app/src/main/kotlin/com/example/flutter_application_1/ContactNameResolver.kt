package com.example.flutter_application_1

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.provider.ContactsContract
import android.telephony.PhoneNumberUtils
import android.util.Log
import androidx.core.content.ContextCompat

object ContactNameResolver {
    private const val TAG = "ContactNameResolver"

    fun resolveDisplayName(context: Context, rawPhone: String): String {
        val phone = rawPhone.trim()
        if (phone.isEmpty()) return rawPhone

        if (
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.READ_CONTACTS
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return rawPhone
        }

        return try {
            val lookupUri = ContactsContract.PhoneLookup.CONTENT_FILTER_URI.buildUpon()
                .appendPath(android.net.Uri.encode(phone))
                .build()

            context.contentResolver.query(
                lookupUri,
                arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val name =
                        cursor.getString(
                            cursor.getColumnIndexOrThrow(
                                ContactsContract.PhoneLookup.DISPLAY_NAME
                            )
                        )?.trim()
                    if (!name.isNullOrEmpty()) {
                        return name
                    }
                }
            }

            val normalizedPhone = normalizePhone(phone)
            if (normalizedPhone.isEmpty()) return rawPhone

            context.contentResolver.query(
                ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                arrayOf(
                    ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                    ContactsContract.CommonDataKinds.Phone.NUMBER,
                ),
                null,
                null,
                null
            )?.use { cursor ->
                val nameIndex =
                    cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
                val numberIndex =
                    cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER)
                while (cursor.moveToNext()) {
                    if (nameIndex == -1 || numberIndex == -1) continue
                    val candidateNumber = cursor.getString(numberIndex) ?: continue
                    if (normalizePhone(candidateNumber) == normalizedPhone) {
                        val candidateName = cursor.getString(nameIndex)?.trim()
                        if (!candidateName.isNullOrEmpty()) {
                            return candidateName
                        }
                    }
                }
            }

            rawPhone
        } catch (e: Exception) {
            Log.e(TAG, "Failed to resolve contact name: ${e.message}", e)
            rawPhone
        }
    }

    private fun normalizePhone(rawPhone: String): String {
        val normalized = PhoneNumberUtils.normalizeNumber(rawPhone)
        if (normalized.isEmpty()) return ""
        val digits = normalized.filter { it.isDigit() }
        if (digits.length >= 10) {
            return digits.takeLast(10)
        }
        return digits
    }
}
