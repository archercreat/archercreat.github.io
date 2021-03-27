#!/bin/bash
git add .
git commit -m "PogChamp"
git push

# save blog backup
7z a blog_backup.7z *
mv blog_backup.7z /mnt/c/Users/Archer/iCloudDrive/
