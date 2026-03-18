# Moved blocks — safe resource renames without destroy/recreate (Terraform 1.1+)
#
# When renaming a resource, add a moved block here so Terraform updates the
# state in-place instead of destroying the old resource and creating a new one.
#
# Example:
#   moved {
#     from = aws_instance.main
#     to   = aws_instance.rockport
#   }
#
# Remove moved blocks after all environments have applied the rename.
