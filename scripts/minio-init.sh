#!/bin/sh
set -eu

require_env() {
  for key in "$@"; do
    eval "value=\${$key:-}"
    if [ -z "${value}" ]; then
      echo "Environment variable is required: ${key}" >&2
      exit 1
    fi
  done
}

require_env \
  MINIO_ENDPOINT \
  MINIO_ROOT_USER \
  MINIO_ROOT_PASSWORD \
  MINIO_BACKUP_USER \
  MINIO_BACKUP_PASSWORD \
  BUCKET_BACKUP_NAME

if [ "${MINIO_BACKUP_USER}" = "${MINIO_ROOT_USER}" ]; then
  echo "MINIO_BACKUP_USER must not be equal to MINIO_ROOT_USER" >&2
  exit 1
fi

alias_name="local"
policy_name="backup-bucket-policy"

echo "Waiting for MinIO endpoint: ${MINIO_ENDPOINT}"
until mc alias set "${alias_name}" "${MINIO_ENDPOINT}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" >/dev/null 2>&1; do
  sleep 2
done

echo "Creating bucket if needed: ${BUCKET_BACKUP_NAME}"
mc mb --ignore-existing "${alias_name}/${BUCKET_BACKUP_NAME}"

policy_file="$(mktemp)"
cat >"${policy_file}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::${BUCKET_BACKUP_NAME}"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::${BUCKET_BACKUP_NAME}/*"
      ]
    }
  ]
}
EOF

if mc admin policy create "${alias_name}" "${policy_name}" "${policy_file}" >/dev/null 2>&1; then
  :
elif mc admin policy add "${alias_name}" "${policy_name}" "${policy_file}" >/dev/null 2>&1; then
  :
elif mc admin policy info "${alias_name}" "${policy_name}" >/dev/null 2>&1; then
  echo "Policy ${policy_name} already exists. Reusing it."
else
  echo "Failed to create MinIO policy ${policy_name}" >&2
  rm -f "${policy_file}"
  exit 1
fi
rm -f "${policy_file}"

if mc admin user info "${alias_name}" "${MINIO_BACKUP_USER}" >/dev/null 2>&1; then
  mc admin user remove "${alias_name}" "${MINIO_BACKUP_USER}"
fi
mc admin user add "${alias_name}" "${MINIO_BACKUP_USER}" "${MINIO_BACKUP_PASSWORD}"

if mc admin policy attach "${alias_name}" "${policy_name}" --user "${MINIO_BACKUP_USER}" >/dev/null 2>&1; then
  :
elif mc admin policy set "${alias_name}" "${policy_name}" user="${MINIO_BACKUP_USER}" >/dev/null 2>&1; then
  :
else
  echo "Failed to attach policy ${policy_name} to user ${MINIO_BACKUP_USER}" >&2
  exit 1
fi

echo "MinIO initialization completed."
